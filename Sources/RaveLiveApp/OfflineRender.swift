// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import Metal
import MetalKit
import QuartzCore

/// The clock the render path reads. Real host time normally. `--offscreen` sets `fixed` and moves it by exactly one
/// frame per draw, so a render never depends on how busy the machine is and the same seed gives the same frames.
/// `CACurrentMediaTime()` and the CoreMedia host clock (`hostNow()`) share one timebase, so one value serves both.
enum RenderClock {
    nonisolated(unsafe) static var fixed: Double?
    /// Seed for the show's shuffle bags (SHOW playlist, Classic preset order). Random per launch; `--seed N` fixes it.
    nonisolated(unsafe) static var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    static func now() -> Double { fixed ?? CACurrentMediaTime() }
}

/// Small seeded generator (xorshift64*) for the shuffle bags, so `--seed` makes a whole set repeatable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2685821657736338717
    }
}

extension Renderer {
    /// Command-line flags that set up what the renderer shows (shared by the app window and `--offscreen`).
    func applyLaunchFlags(_ args: [String]) {
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        forcedLook = arg("--look").flatMap(Float.init); forcedBeam = arg("--beam").flatMap(Float.init); forcedLaser = arg("--laser").flatMap(Float.init)
        if args.contains("--visuals") { mode = .visuals }
        if args.contains("--stage") { mode = .stage }
        if args.contains("--aurora") { mode = .aurora }
        if args.contains("--show") { mode = .show }
        if let sd = arg("--snapdir") { snapDir = URL(fileURLWithPath: NSString(string: sd).expandingTildeInPath) }
        fakeMouseFrom = arg("--fakemouse-from").flatMap(Double.init) ?? -1
        fakeHandsFrom = arg("--fakehands-from").flatMap(Double.init) ?? 0
        fakeHands = args.contains("--fakehands") || arg("--fakehands-from") != nil
        if let iv = arg("--intensity").flatMap(Int.init), let it = Renderer.Intensity(rawValue: iv) { intensity = it }
        if let tr = arg("--trim").flatMap(Double.init) { userOffset = tr / 1000 }
        if let pr = arg("--preset").flatMap(Int.init) { visuals?.preset = pr; visuals?.autoCycle = false }
        if let s = arg("--snap") { snapTimes = s.split(separator: ",").compactMap { Double($0) }.sorted() }
        snapTransitions = arg("--snap-transitions").flatMap(Int.init) ?? 0
        showHoldOverride = arg("--show-hold").flatMap(Double.init)
        lumLogPath = arg("--lumlog").map { NSString(string: $0).expandingTildeInPath }
        if let sl = arg("--smoothlog") { smooth = SmoothProbe(device: device, path: NSString(string: sl).expandingTildeInPath) }
        if args.contains("--no-drop-fx") { dropFX?.enabled = false }
    }
}

/// `--offscreen`: render the show into a texture with no window, no Dock icon and no audio capture, on a fixed clock.
///
///     RaveLive --offscreen --demo --seconds 45 --fps 60 --width 1280 --height 720 --seed 7 \
///              --snap 10,34,40 --snapdir DIR --metrics DIR/metrics.json [--frames DIR --frame-step 2] [--realtime] [--stage|--show|...]
///
/// Every frame advances the clock by exactly 1/fps and first feeds the demo track up to that time, so the analyzer,
/// the beat clock and the show director see the same input whatever the machine load: two runs with one seed give the
/// same frames, and `--frames` writes a gap-free image sequence for video. Nothing is ever shown on screen, so it is
/// safe on a machine someone is using and on CI. `perf` in the metrics folder (`offscreen.json`) holds the real cost of
/// each frame (CPU encode, and CPU + GPU until the frame is done), which is what the fixed clock can't measure.
enum OfflineRender {
    struct Options {
        var seconds = 45.0, fps = 60.0, width = 1280, height = 720
        var framesDir: URL?, frameStep = 1, frameFrom = 0.0
        var metrics: URL?
        var realtime = false
    }

    static func options(_ args: [String]) -> Options {
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        var o = Options()
        o.seconds = max(0.1, arg("--seconds").flatMap(Double.init) ?? arg("--autoquit").flatMap(Double.init) ?? o.seconds)
        o.fps = min(240, max(10, arg("--fps").flatMap(Double.init) ?? o.fps))
        o.width = max(16, arg("--width").flatMap(Int.init) ?? o.width)
        o.height = max(16, arg("--height").flatMap(Int.init) ?? o.height)
        o.framesDir = arg("--frames").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        o.frameStep = max(1, arg("--frame-step").flatMap(Int.init) ?? 1)
        o.frameFrom = max(0, arg("--frames-from").flatMap(Double.init) ?? 0)
        o.metrics = arg("--metrics").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        o.realtime = args.contains("--realtime")
        return o
    }

    /// `--offscreen` keeps away from the user's own RAVE LIVE data (Shader Lab folder, MilkDrop library, look tweaks,
    /// saved settings), so frames don't depend on whose Mac renders them and a run never changes them.
    static func isolates(args: [String]) -> Bool { args.contains("--offscreen") }

    /// The host time an offscreen run starts at (any fixed value works; this one looks like a normal uptime).
    static let startHostTime = 10_000.0

    /// A renderer drawing into its own texture, with a view that never draws by itself and has no window.
    struct Rig { let renderer: Renderer; let view: MTKView; let audio: AudioEngine }

    /// Builds the renderer for an offscreen run. Call after setting `RenderClock.fixed` (the show's clock starts here).
    static func makeRig(device: MTLDevice, width: Int, height: Int, quality: String) -> Rig? {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true; view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: width, height: height)
        QualityController.shared.setUp(view: view, override: quality)
        let audio = AudioEngine()
        audio.refereeEnabled = false
        guard let r = Renderer(view: view, audio: audio) else { return nil }
        QualityController.shared.attach(r)
        r.renderOffscreen = true
        // nothing is played, so this Mac's speakers or headphones must not shift the beat grid (RAVE_TEST_OUTPUT_LATENCY_MS still works)
        r.outputLatency = OutputLatency.testOverride() ?? .init(seconds: 0, name: "offscreen", transport: "none")
        return Rig(renderer: r, view: view, audio: audio)
    }

    /// Draws frame `index` (1-based) of a run that started at host time `start`: moves the clock, feeds the demo up to
    /// it, draws, and waits for the GPU. Returns (CPU encode, CPU + GPU) seconds.
    @discardableResult
    static func step(_ rig: Rig, index: Int, start: Double, fps: Double, demo: Bool) -> (cpu: Double, total: Double) {
        let t = start + Double(index) / fps
        RenderClock.fixed = t
        if demo { rig.audio.pumpDemo(until: t) }
        let c0 = CACurrentMediaTime()
        autoreleasepool { rig.renderer.draw(in: rig.view) }
        let c1 = CACurrentMediaTime()
        // the queue runs in order: once this buffer completes, the frame's GPU work is done. Discrete GPUs (Intel Macs)
        // keep the frame in managed memory, so copy it back for `--frames` here too.
        if let cb = rig.renderer.queue.makeCommandBuffer() {
            if let tex = rig.renderer.offscreenFrame, tex.storageMode == .managed, let b = cb.makeBlitCommandEncoder() { b.synchronize(resource: tex); b.endEncoding() }
            cb.commit(); cb.waitUntilCompleted()
        }
        return (c1 - c0, CACurrentMediaTime() - c0)
    }

    /// Runs the whole render and returns the process exit code.
    static func run(_ args: [String]) -> Int32 {
        let o = options(args)
        if let s = args.firstIndex(of: "--seed").flatMap({ args.count > $0 + 1 ? UInt64(args[$0 + 1]) : nil }) { RenderClock.seed = s }
        // No Dock icon, no menu bar, never activated: nothing can appear on screen or take focus.
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let dev = MTLCreateSystemDefaultDevice() else { FileHandle.standardError.write("offscreen: no Metal device\n".data(using: .utf8)!); return 2 }
        // A fixed host time, not this Mac's uptime: before the beat locks, the director counts phrases on the host clock
        // (every 8 s), so starting at a different uptime would pick different looks.
        let start = startHostTime
        RenderClock.fixed = start
        let quality = args.firstIndex(of: "--quality").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "high"
        guard let rig = makeRig(device: dev, width: o.width, height: o.height, quality: quality) else {
            FileHandle.standardError.write("offscreen: renderer failed\n".data(using: .utf8)!); return 3
        }
        let r = rig.renderer
        r.applyLaunchFlags(args)
        let demo = args.contains("--demo")
        if demo { rig.audio.prepareDemo(at: start) }
        if let d = o.framesDir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let frames = Int((o.seconds * o.fps).rounded())
        var cpu = [Double](), total = [Double](), gpu = [Double]()
        cpu.reserveCapacity(frames); total.reserveCapacity(frames); gpu.reserveCapacity(frames)
        var written = 0
        let wall0 = CACurrentMediaTime()
        for i in 0..<frames {
            // --realtime: no faster than the clock, so the GPU load matches the live app at this frame rate
            if o.realtime { let due = wall0 + Double(i) / o.fps - CACurrentMediaTime(); if due > 0 { Thread.sleep(forTimeInterval: due) } }
            let (c, t) = step(rig, index: i + 1, start: start, fps: o.fps, demo: demo)
            cpu.append(c); total.append(t)
            gpu.append(r.metrics.summary(recent: 1).gpuP95)          // this frame's GPU time (its handler ran before the wait returned)
            let elapsed = Double(i + 1) / o.fps
            if let dir = o.framesDir, elapsed >= o.frameFrom, i % o.frameStep == 0, let tex = r.offscreenFrame {
                Renderer.writePNG(tex, to: dir.appendingPathComponent(String(format: "f_%05d.png", written)))
                written += 1
            }
            // let main-queue work queued by the renderers (Shader Lab polling, metrics hooks) run between frames
            RunLoop.main.run(mode: .default, before: Date())
        }
        r.metrics.sync = r.syncInfo
        if let m = o.metrics {
            try? FileManager.default.createDirectory(at: m.deletingLastPathComponent(), withIntermediateDirectories: true)
            r.metrics.dump(to: m, wait: true)
            writePerf(cpu: cpu, total: total, gpu: gpu, o: o, frames: written, to: m.deletingLastPathComponent().appendingPathComponent("offscreen.json"))
        }
        r.smooth?.finish()
        let p = percentiles(Array(total.dropFirst(30)))
        print(String(format: "offscreen: %d frames (%.1f s at %.0f fps, %dx%d) in %.1f s; frame cost p50 %.2f ms p95 %.2f ms p99 %.2f ms; %d frames written",
                     frames, o.seconds, o.fps, o.width, o.height, CACurrentMediaTime() - wall0, p.0 * 1000, p.1 * 1000, p.2 * 1000, written))
        return 0
    }

    static func percentiles(_ a: [Double]) -> (Double, Double, Double) {
        guard !a.isEmpty else { return (.nan, .nan, .nan) }
        let s = a.sorted()
        func q(_ f: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * f))] }
        return (q(0.5), q(0.95), q(0.99))
    }

    private static func writePerf(cpu: [Double], total: [Double], gpu: [Double], o: Options, frames: Int, to url: URL) {
        func j(_ v: Double) -> Any { v.isFinite ? v * 1000 : NSNull() }
        func block(_ a: [Double]) -> [String: Any] { let p = percentiles(a); return ["p50": j(p.0), "p95": j(p.1), "p99": j(p.2), "max": j(a.max() ?? .nan)] }
        // the first 30 frames (pipeline creation, first texture allocations) are left out, like the live metrics
        let skip = min(30, max(0, total.count - 1))
        // per second of show time, to see what a build or a drop costs
        var perSecond: [[String: Any]] = []
        let n = Int(o.fps.rounded())
        var i = 0
        while i < total.count {
            let k = min(total.count, i + n)
            perSecond.append(["t": Double(k) / o.fps, "gpu_ms_p95": j(percentiles(Array(gpu[i..<k])).1), "frame_cost_ms_p95": j(percentiles(Array(total[i..<k])).1)])
            i = k
        }
        let t = percentiles(Array(total.dropFirst(skip)))
        let d: [String: Any] = [
            "frames": total.count, "seconds": o.seconds, "fps_clock": o.fps, "width": o.width, "height": o.height, "realtime": o.realtime,
            "seed": String(RenderClock.seed), "frames_written": frames,
            "cpu_encode_ms": block(Array(cpu.dropFirst(skip))),
            "gpu_ms": block(Array(gpu.dropFirst(skip)).filter { $0.isFinite }),
            "frame_cost_ms": block(Array(total.dropFirst(skip))),
            "max_fps_from_p50": t.0 > 0 ? 1 / t.0 : NSNull(),
            "per_second": perSecond,
            "load_average": ProcessInfo.processInfo.loadAverage,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}

extension ProcessInfo {
    /// 1, 5 and 15 minute load averages (the offscreen perf numbers depend on how busy the machine was).
    var loadAverage: [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }
}
