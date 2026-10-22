import AVFoundation
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

/// System-audio capture through ScreenCaptureKit (no virtual driver needed).
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

/// Microphone / audio-interface fallback (turntables, line-in, no Screen Recording permission).
public final class MicCapture: @unchecked Sendable {
    public var onSamples: SampleHandler?
    private let engine = AVAudioEngine()
    public init() {}
    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    public func start() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        var mono = [Float](repeating: 0, count: 4096)
        input.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buf, when in
            guard let ch = buf.floatChannelData else { return }
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
    public func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop() }
}
