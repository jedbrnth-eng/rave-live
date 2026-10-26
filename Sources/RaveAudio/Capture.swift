// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Delivered on the capture queue: mono float samples, sample rate, presentation time (s).
public typealias SampleHandler = (UnsafeBufferPointer<Float>, Double, Double) -> Void

public enum CapturePermission {
    /// True when Screen Recording (needed for system audio) is already granted.
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt (first time only). Returns current state.
    @discardableResult public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }
    public static let fixInstructions = """
    RAVE LIVE needs Screen & System Audio Recording to hear what your Mac is playing.
    It never records your screen; it only reads the audio.
    Fix: System Settings → Privacy & Security → Screen & System Audio Recording →
    turn on RAVE LIVE (or your terminal app), then quit and reopen it.
    No permission? Use microphone input instead (press M).
    """
    /// Shown on macOS 12, where ScreenCaptureKit can't capture audio.
    public static let macOS12Instructions = """
    System audio capture needs macOS 13 or newer. On macOS 12, RAVE LIVE listens to an input device:
    pick one in the Audio menu (microphone, audio interface, DJ mixer), or install a free loopback
    driver such as BlackHole, send your music to it and choose it there.
    """
}

/// System audio (ScreenCaptureKit) needs macOS 13; on macOS 12 only input devices are available.
/// Env RAVE_NO_SYSTEM_AUDIO=1 makes a newer Mac behave like macOS 12 here (for testing the fallback).
public enum SystemAudio {
    public static var isSupported: Bool {
        if ProcessInfo.processInfo.environment["RAVE_NO_SYSTEM_AUDIO"] != nil { return false }
        if #available(macOS 13.0, *) { return true }
        return false
    }
}

public enum CaptureError: Error, CustomStringConvertible {
    case noDisplay, permissionDenied(String)
    public var description: String {
        switch self {
        case .noDisplay: return "No display available for ScreenCaptureKit filter"
        case .permissionDenied(let s): return "Permission denied: \(s)"
        }
    }
}

/// System-audio capture through ScreenCaptureKit (no virtual driver needed). macOS 13+ (SCK audio).
@available(macOS 13.0, *)
public final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public var onSamples: SampleHandler?
    public var onError: ((Error) -> Void)?
    public private(set) var droppedGaps = 0
    public private(set) var buffersReceived = 0
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "rave.audio.capture", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "rave.video.discard", qos: .background)
    private var mono = [Float]()
    private var expectedPTS: Double?

    public override init() { super.init() }

    public func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await s.startCapture()
        stream = s
    }

    public func stop() async { try? await stream?.stopCapture(); stream = nil }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        guard let fmt = sb.formatDescription?.audioStreamBasicDescription else { return }
        let sr = fmt.mSampleRate
        let pts = sb.presentationTimeStamp.seconds
        let frames = sb.numSamples
        if let e = expectedPTS, pts - e > 1.5 * Double(frames) / sr { droppedGaps += 1 }
        expectedPTS = pts + Double(frames) / sr
        buffersReceived += 1
        do {
            try sb.withAudioBufferList { abl, _ in
                let nonInterleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
                if nonInterleaved {
                    let chans = abl.count
                    for i in 0..<frames { mono[i] = 0 }
                    for buf in abl {
                        guard let d = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<frames { mono[i] += d[i] }
                    }
                    let g = 1 / Float(max(1, chans))
                    for i in 0..<frames { mono[i] *= g }
                } else if let d = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                    let ch = Int(fmt.mChannelsPerFrame)
                    for i in 0..<frames {
                        var s: Float = 0
                        for c in 0..<ch { s += d[i * ch + c] }
                        mono[i] = s / Float(ch)
                    }
                }
                mono.withUnsafeBufferPointer { p in
                    onSamples?(UnsafeBufferPointer(rebasing: p[0..<frames]), sr, pts)
                }
            }
        } catch { onError?(error) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
}

/// A CoreAudio device with at least one input channel (mic, interface, DJ mixer, BlackHole/Loopback).
public struct AudioInputDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let channels: Int

    /// Every device that can record, in CoreAudio order.
    public static func all() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [AudioInputDevice] = []
        for id in ids {
            let ch = inputChannels(id)
            guard ch > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { continue }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            out.append(AudioInputDevice(id: id, uid: uid, name: name, channels: ch))
        }
        return out
    }

    /// The system default input device, if any.
    public static func defaultInput() -> AudioInputDevice? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return all().first { $0.id == id }
    }

    /// First device whose name (or UID) contains `query`, case-insensitive.
    public static func matching(_ query: String) -> AudioInputDevice? {
        let q = query.lowercased()
        let list = all()
        return list.first { $0.name.lowercased() == q } ?? list.first { $0.name.lowercased().contains(q) || $0.uid.lowercased().contains(q) }
    }

    /// Calls `handler` on the main queue whenever devices are added or removed. Keep the returned token alive.
    public static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        DeviceListObserver(handler)
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var n = 0
        for b in abl { n += Int(b.mNumberChannels) }
        return n
    }

    private static func stringProperty(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

private final class DeviceListObserver {
    private var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let block: AudioObjectPropertyListenerBlock
    init(_ handler: @escaping @Sendable () -> Void) {
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }
    deinit { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) }
}

/// Input-device capture: mic, audio interface, DJ mixer, loopback driver (and the only source on macOS 12).
public final class MicCapture: @unchecked Sendable {
    public var onSamples: SampleHandler?
    public private(set) var buffersReceived = 0
    private var engine = AVAudioEngine()
    private var hal: HALInput?
    public init() {}
    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    /// "granted", "denied", "restricted" or "not determined" (no prompt shown).
    public static var permissionStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not determined"
        }
    }
    /// Starts capturing from `device`, or from the system default input when nil.
    public func start(device: AudioInputDevice? = nil) throws {
        stop()
        buffersReceived = 0
        // Preferred: an input-only AUHAL on the device, 512-frame buffers. (AVAudioEngine taps arrive in ~100 ms
        // chunks, and pointing its shared input/output AUHAL at an input-only device silently delivers nothing.)
        if let device = device ?? AudioInputDevice.defaultInput() {
            let h = HALInput(device: device)
            h.onBuffer = { [weak self] buf, sr, t in self?.buffersReceived += 1; self?.onSamples?(buf, sr, t) }
            do { try h.start(); hal = h; return } catch { h.stop(); NSLog("RaveAudio: %@; falling back to AVAudioEngine", error.localizedDescription) }
        }
        engine = AVAudioEngine()   // fallback: the current default input
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "RaveAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input device available"])
        }
        var mono = [Float](repeating: 0, count: 4096)
        input.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buf, when in
            guard let ch = buf.floatChannelData else { return }
            self?.buffersReceived += 1
            let n = Int(buf.frameLength), cc = Int(buf.format.channelCount)
            if mono.count < n { mono = [Float](repeating: 0, count: n) }
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<cc { s += ch[c][i] }
                mono[i] = s / Float(cc)
            }
            let t = AVAudioTime.seconds(forHostTime: when.hostTime)
            mono.withUnsafeBufferPointer { self?.onSamples?(UnsafeBufferPointer(rebasing: $0[0..<n]), fmt.sampleRate, t) }
        }
        try engine.start()
    }
    public func stop() {
        hal?.stop(); hal = nil
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
    }
}

/// Input-only AUHAL on one specific CoreAudio device: Float32 non-interleaved, mixed to mono, host-time stamps.
private final class HALInput {
    var onBuffer: SampleHandler?
    private let device: AudioInputDevice
    private var unit: AudioUnit?
    private var channels = 1
    private var sampleRate = 48000.0
    private var abl: UnsafeMutableAudioBufferListPointer?
    private var mono = [Float](repeating: 0, count: 8192)
    private static let maxFrames = 8192

    init(device: AudioInputDevice) { self.device = device }
    deinit { stop() }

    private func check(_ err: OSStatus, _ what: String) throws {
        if err != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Can't open input \"\(device.name)\": \(what) failed (\(err))"])
        }
    }

    func start() throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { try check(-1, "AUHAL lookup"); return }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "AUHAL")
        guard let unit = u else { return }
        self.unit = unit
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        var on: UInt32 = 1, off: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable output")
        var id = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "read format")
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0 else { try check(-1, "device format"); return }
        sampleRate = hw.mSampleRate
        channels = Int(hw.mChannelsPerFrame)
        var fmt = AudioStreamBasicDescription(mSampleRate: hw.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: hw.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, size), "set format")
        var frames: UInt32 = 512   // same buffer size as the default-input path (low latency)
        _ = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, u32)
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for c in 0..<channels {
            list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * 4),
                                  mData: UnsafeMutableRawPointer.allocate(byteCount: Self.maxFrames * 4, alignment: 16))
        }
        abl = list
        var cb = AURenderCallbackStruct(inputProc: { ref, flags, ts, bus, n, _ in
            Unmanaged<HALInput>.fromOpaque(ref).takeUnretainedValue().render(flags, ts, bus, n)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
        try check(AudioUnitInitialize(unit), "initialise")
        try check(AudioOutputUnitStart(unit), "start")
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ n: UInt32) -> OSStatus {
        guard let unit, let abl, Int(n) <= Self.maxFrames else { return noErr }
        for c in 0..<abl.count { abl[c].mDataByteSize = n * 4 }
        let err = AudioUnitRender(unit, flags, ts, bus, n, abl.unsafeMutablePointer)
        guard err == noErr else { return err }
        let frames = Int(n)
        for i in 0..<frames { mono[i] = 0 }
        for c in 0..<abl.count {
            guard let d = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames { mono[i] += d[i] }
        }
        let g = 1 / Float(max(1, abl.count))
        for i in 0..<frames { mono[i] *= g }
        let t = AVAudioTime.seconds(forHostTime: ts.pointee.mHostTime)
        mono.withUnsafeBufferPointer { onBuffer?(UnsafeBufferPointer(rebasing: $0[0..<frames]), sampleRate, t) }
        return noErr
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        if let abl {
            for b in abl { b.mData?.deallocate() }
            free(abl.unsafeMutablePointer)
        }
        abl = nil
    }
}
