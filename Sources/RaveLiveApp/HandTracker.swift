import AVFoundation
import CoreImage
import Vision

/// Camera input for AURORA: hand pose (index tip + pinch) and a person-segmentation mask.
/// Everything stays on-device (Vision); nothing is recorded or saved.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Hand { var pos: SIMD2<Float>; var pinch: Bool }
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "rave.camera", qos: .userInitiated)
    private let lock = NSLock()
    private var _hands: [Hand] = []
    private var _mask: [UInt8]?
    private var maskSeq = 0
    private(set) var running = false
    var wantMask = true
    var onStatus: ((String) -> Void)?
    private let handReq: VNDetectHumanHandPoseRequest = { let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2; return r }()
    private let segReq: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .fast; r.outputPixelFormat = kCVPixelFormatType_OneComponent8; return r
    }()
    private var frame = 0

    var hands: [Hand] { lock.lock(); defer { lock.unlock() }; return _hands }
    /// Returns a new 256x144 mask once per camera frame (nil if unchanged).
    func takeMask() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; let m = _mask; _mask = nil; return m }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.onStatus?("Camera access denied. Enable it in System Settings → Privacy & Security → Camera → RAVE LIVE. Mouse still works."); return }
            self.queue.async { self.configure() }
        }
    }
    func stop() { queue.async { self.session.stopRunning(); self.running = false } }

    private func configure() {
        guard !running else { return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let dev = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first
            ?? AVCaptureDevice.default(for: .video)
        guard let dev, let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration(); onStatus?("No camera found. Mouse still works."); return
        }
        session.inputs.forEach { session.removeInput($0) }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        session.startRunning()
        running = true
        onStatus?("")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
        frame += 1
        let h = VNImageRequestHandler(cvPixelBuffer: px, orientation: .up)
        var reqs: [VNRequest] = [handReq]
        if wantMask && frame % 2 == 0 { reqs.append(segReq) }
        try? h.perform(reqs)
        var hs: [Hand] = []
        for o in handReq.results ?? [] {
            guard let tip = try? o.recognizedPoint(.indexTip), tip.confidence > 0.3 else { continue }
            var pinch = false
            if let th = try? o.recognizedPoint(.thumbTip), th.confidence > 0.3 {
                pinch = hypot(tip.location.x - th.location.x, tip.location.y - th.location.y) < 0.045
            }
            // Vision: origin bottom-left, normalized. Mirror x so it behaves like a mirror.
            hs.append(Hand(pos: SIMD2<Float>(Float(1 - tip.location.x), Float(1 - tip.location.y)), pinch: pinch))
        }
        var maskBytes: [UInt8]?
        if let m = segReq.results?.first?.pixelBuffer, reqs.count > 1 { maskBytes = Self.downsample(m) }
        lock.lock(); _hands = hs; if let mb = maskBytes { _mask = mb }; lock.unlock()
    }

    /// Scale the Vision mask to 256x144, mirrored, top-left origin.
    static func downsample(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var out = [UInt8](repeating: 0, count: 256 * 144)
        for y in 0..<144 {
            let sy = min(h - 1, y * h / 144)
            for x in 0..<256 {
                let sx = min(w - 1, (255 - x) * w / 256)
                out[y * 256 + x] = base[sy * bpr + sx]
            }
        }
        return out
    }
}
