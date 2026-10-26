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
public enum SystemAudio {
    public static var isSupported: Bool {
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
    public init() {}
    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    /// Starts capturing from `device`, or from the system default input when nil.
    public func start(device: AudioInputDevice? = nil) throws {
        engine = AVAudioEngine()   // a fresh engine picks up the newly chosen device's format
        buffersReceived = 0
        let input = engine.inputNode
        if let device, let unit = input.audioUnit {
            var id = device.id
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                                            userInfo: [NSLocalizedDescriptionKey: "Can't select input \"\(device.name)\" (error \(err))"]) }
        }
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
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
    }
}
