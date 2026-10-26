// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import IOSurface
import Metal
import OpenGL
import OpenGL.GL3
import QuartzCore

/// MILKDROP mode: projectM renders MilkDrop presets with OpenGL into IOSurfaces on its own thread; the IOSurfaces are
/// wrapped as Metal textures (zero copy) and composited by the Metal render loop like any other scene.
/// The Metal side never waits for GL: each frame it asks for a new GL frame if the GL thread is idle and shows the
/// newest finished one. RAVE LIVE drives preset changes on the beat grid (MilkDropDirector) instead of projectM's timer.
final class MilkDropRenderer: @unchecked Sendable {
    let device: MTLDevice
    let lib = MilkDropLib.shared
    let library: MilkDropLibrary
    private let comp: MTLRenderPipelineState
    private let glQueue = DispatchQueue(label: "rave.milkdrop.gl", qos: .userInteractive)

    // GL thread only
    private var cgl: CGLContextObj?
    private var pm: MilkDropLib.Handle?
    private struct Target { let surface: IOSurfaceRef; let glTex: GLuint; let fbo: GLuint; let mtl: MTLTexture; let w: Int; let h: Int }
    private var targets: [Target] = []
    private var nextTarget = 0
    private var pmSize = (0, 0)
    private var framesSinceLoad = 0
    private var lumaSamples: [(mean: Double, peak: Double)] = []
    private var glFailed = false
    private var pcmScratch: [Float] = []

    // shared, under `lock`
    private let lock = NSLock()
    private var published: MTLTexture?
    private var busy = false
    private var commands: [Command] = []
    private var pcm: [Float] = []
    private(set) var current: MilkDropLibrary.Preset?
    private var loadFailure: String?
    /// Last GL frame time (ms) and preset load time (ms), for the HUD/metrics.
    private(set) var glFrameMs = 0.0, lastLoadMs = 0.0
    /// Shown on the card when MILKDROP can't run.
    var problem: String {
        if lib == nil { return "MilkDrop engine (libprojectM) missing. " + MilkDropLib.loadError }
        if glFailed { return "Couldn't create the OpenGL context projectM needs." }
        if library.isEmpty { return "No MilkDrop presets yet." }
        return ""
    }
    var ready: Bool { problem.isEmpty }

    var director = MilkDropDirector()
    /// Called on the GL thread when a preset was loaded / skipped (event text for the metrics log).
    var onEvent: ((String) -> Void)?
    /// Test sweep (`--milk-sweep N`): load N presets one after another, classify each as ok / failed / black.
    var sweep: Sweep?

    private enum Command { case load(MilkDropLibrary.Preset, smooth: Bool, blend: Double, why: String) }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, library: MilkDropLibrary) {
        self.device = device; self.library = library
        do {
            let l = try device.makeLibrary(source: milkDropShaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = l.makeFunction(name: "mvert"); d.fragmentFunction = l.makeFunction(name: "mfrag")
            d.colorAttachments[0].pixelFormat = pixelFormat
            comp = try device.makeRenderPipelineState(descriptor: d)
        } catch { NSLog("MilkDrop shader error: \(error)"); return nil }
    }

    // MARK: - audio (capture queue)

    /// Mono capture samples; drained into projectM on the GL thread each frame. Keeps at most ~1 s.
    func feed(_ buf: UnsafeBufferPointer<Float>) {
        lock.lock()
        pcm.append(contentsOf: buf)
        if pcm.count > 48_000 { pcm.removeFirst(pcm.count - 48_000) }
        lock.unlock()
    }

    // MARK: - preset control (any thread)

    func load(_ p: MilkDropLibrary.Preset, smooth: Bool, blendSeconds: Double = 2, why: String) {
        lock.lock(); commands.append(.load(p, smooth: smooth, blend: blendSeconds, why: why)); lock.unlock()
    }
    /// Pick and load the next automatic preset. Returns its name (nil when the library is empty).
    @discardableResult func loadNext(loud: Bool, smooth: Bool, blendSeconds: Double, why: String) -> String? {
        guard let p = library.pick(loud: loud) else { return nil }
        load(p, smooth: smooth, blendSeconds: blendSeconds, why: why)
        return p.name
    }
    func step(_ dir: Int) {
        lock.lock(); let key = current?.key; lock.unlock()
        if let p = library.neighbour(of: key, step: dir) { load(p, smooth: false, why: dir > 0 ? "next" : "prev") }
    }
    var currentName: String { lock.lock(); defer { lock.unlock() }; return current.map { ($0.author.isEmpty ? "" : $0.author + " - ") + $0.name } ?? "" }

    /// Beat-locked automatic changes (MILKDROP mode). Returns the event text when it switched.
    func direct(beat: Int, phase: Double, beatLocked: Bool, dropStarted: Bool, now: Double, energy: Float, intensity: Int, bpm: Double) -> String? {
        guard ready, sweep == nil else { return nil }
        director.holdBeats = MilkDropDirector.hold(intensity: intensity, energy: energy)
        let a = director.step(beat: beat, beatLocked: beatLocked, dropStarted: dropStarted, now: now)
        guard a != .none else { return nil }
        let blend = MilkDropDirector.blendSeconds(bpm: beatLocked ? bpm : 0)
        guard let name = loadNext(loud: a == .cut || energy > 0.6, smooth: a == .blend, blendSeconds: blend, why: a == .cut ? "cut" : "blend") else { return nil }
        return String(format: "milk:%@ beat=%d bar=%d phrase=%d phase=%.3f locked=%d %@", a == .cut ? "cut(drop)" : "blend", beat,
                      MilkDropDirector.mod(beat, 4), MilkDropDirector.mod(beat, 16), phase, beatLocked ? 1 : 0, name)
    }

    // MARK: - Metal side (render thread)

    /// Draw the newest projectM frame into `rpd` and kick off the next GL frame if the GL thread is free.
    /// u = Renderer's uniform table (kick u[9], fade u[16], blackout u[15], blinder u[33], build u[34]).
    func encode(cb: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, size: CGSize, u: [Float], playing: Bool) {
        if ready { requestFrame(size: size, sensitivity: 1 + u[34] * 1.5 + u[17], playing: playing) }
        lock.lock(); let tex = published; lock.unlock()
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var mu: [Float] = [tex != nil ? 1 : 0, u[2], u[9], u[34], u[17], u[33], u[16], u[15], Float(size.width / max(1, size.height))]
        enc.setRenderPipelineState(comp)
        if let tex { enc.setFragmentTexture(tex, index: 0) }
        enc.setFragmentBytes(&mu, length: mu.count * 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func requestFrame(size: CGSize, sensitivity: Float, playing: Bool) {
        lock.lock()
        if busy { lock.unlock(); return }     // GL still on the previous frame: show the last one, never wait
        busy = true
        lock.unlock()
        // projectM renders at most 1920 wide; Metal scales it to the drawable
        let scale = min(1, 1920 / max(1, Double(size.width)))
        let w = max(64, Int(Double(size.width) * scale)), h = max(64, Int(Double(size.height) * scale))
        glQueue.async { [weak self] in
            self?.renderGL(w: w, h: h, sensitivity: sensitivity, playing: playing)
            self?.lock.lock(); self?.busy = false; self?.lock.unlock()
        }
    }

    // MARK: - GL thread

    private func setupGL() -> Bool {
        guard let lib else { return false }
        var attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_GL4_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 24),
            CGLPixelFormatAttribute(rawValue: 0),
        ]
        var pf: CGLPixelFormatObj?
        var n: GLint = 0
        guard CGLChoosePixelFormat(&attrs, &pf, &n) == kCGLNoError, let pf else { return false }
        defer { CGLDestroyPixelFormat(pf) }
        var ctx: CGLContextObj?
        guard CGLCreateContext(pf, nil, &ctx) == kCGLNoError, let ctx else { return false }
        cgl = ctx
        CGLSetCurrentContext(ctx)
        guard let h = lib.create() else { return false }
        pm = h
        lib.setPresetDuration(h, 1e7)          // RAVE LIVE decides when presets change
        lib.setHardCutEnabled(h, false)
        lib.setPresetLocked(h, true)
        lib.setFPS(h, 60)
        lib.setMeshSize(h, 64, 48)
        lib.setFailedCallback(h, { file, msg, user in
            guard let user else { return }
            let me = Unmanaged<MilkDropRenderer>.fromOpaque(user).takeUnretainedValue()
            me.loadFailure = msg.map { String(cString: $0) } ?? "load failed"
            _ = file
        }, Unmanaged.passUnretained(self).toOpaque())
        let paths = [MilkDropLibrary.packDir.path, MilkDropLibrary.userDir.path]
        var cstrs = paths.map { UnsafePointer(strdup($0)) }
        cstrs.withUnsafeMutableBufferPointer { b in lib.setTextureSearchPaths(h, b.baseAddress, b.count) }
        for c in cstrs { free(UnsafeMutablePointer(mutating: c)) }
        NSLog("RAVE LIVE: MilkDrop ready (projectM %@ from %@, GL %@)", lib.version, lib.path, String(cString: glGetString(GLenum(GL_VERSION))))
        return true
    }

    private func makeTargets(w: Int, h: Int) {
        for t in targets { var f = t.fbo, x = t.glTex; glDeleteFramebuffers(1, &f); glDeleteTextures(1, &x) }
        targets = []
        let props: [String: Any] = [kIOSurfaceWidth as String: w, kIOSurfaceHeight as String: h, kIOSurfaceBytesPerElement as String: 4,
                                    kIOSurfacePixelFormat as String: 0x4247_5241 /* 'BGRA' */]
        for _ in 0..<3 {
            guard let s = IOSurfaceCreate(props as CFDictionary) else { continue }
            var tex: GLuint = 0, fbo: GLuint = 0
            glGenTextures(1, &tex)
            glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), tex)
            let err = CGLTexImageIOSurface2D(cgl!, GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_RGBA), GLsizei(w), GLsizei(h),
                                             GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV), s, 0)
            glGenFramebuffers(1, &fbo)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_RECTANGLE), tex, 0)
            let complete = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = device.hasUnifiedMemory ? .shared : .managed
            guard err == kCGLNoError, complete, let mt = device.makeTexture(descriptor: d, iosurface: s, plane: 0) else {
                NSLog("RAVE LIVE: MilkDrop IOSurface target failed (cgl %d, fbo complete %d)", err.rawValue, complete ? 1 : 0)
                continue
            }
            targets.append(Target(surface: s, glTex: tex, fbo: fbo, mtl: mt, w: w, h: h))
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    private func renderGL(w: Int, h: Int, sensitivity: Float, playing: Bool) {
        if glFailed { return }
        if pm == nil && !setupGL() { glFailed = true; return }
        guard let lib, let pm, let ctx = cgl else { return }
        CGLSetCurrentContext(ctx)
        if targets.first?.w != w || targets.first?.h != h { makeTargets(w: w, h: h) }
        guard !targets.isEmpty else { glFailed = true; return }
        if pmSize != (w, h) { lib.setWindowSize(pm, w, h); pmSize = (w, h) }

        // sweep: one preset after another
        if var sw = sweep { _ = sw.tick(self); sweep = sw }

        lock.lock(); let cmds = commands; commands = []; swap(&pcm, &pcmScratch); pcm.removeAll(keepingCapacity: true); lock.unlock()
        if current == nil && cmds.isEmpty, let p = library.pick(loud: false) { loadNow(p, smooth: false, blend: 0, why: "start") }
        for c in cmds { if case let .load(p, smooth, blend, why) = c { loadNow(p, smooth: smooth, blend: blend, why: why) } }

        // audio: projectM keeps its own window; give it everything that arrived since the last frame
        if !pcmScratch.isEmpty {
            let maxN = Int(lib.pcmMaxSamples())
            pcmScratch.withUnsafeBufferPointer { b in
                var i = 0
                while i < b.count {
                    let n = min(maxN, b.count - i)
                    lib.pcmAddFloat(pm, b.baseAddress! + i, UInt32(n), 1)
                    i += n
                }
            }
            pcmScratch.removeAll(keepingCapacity: true)
        }
        lib.setBeatSensitivity(pm, sensitivity)

        let t = targets[nextTarget % targets.count]
        nextTarget += 1
        let t0 = CACurrentMediaTime()
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), t.fbo)
        glViewport(0, 0, GLsizei(w), GLsizei(h))
        lib.renderFrameFBO(pm, t.fbo)
        glFinish()          // GL thread only: the Metal loop keeps drawing the previous frame meanwhile
        glFrameMs += 0.1 * ((CACurrentMediaTime() - t0) * 1000 - glFrameMs)
        framesSinceLoad += 1
        lock.lock(); published = t.mtl; lock.unlock()

        if sweep != nil { sweep?.observe(self, surface: t.surface) } else { checkBlack(t.surface, playing: playing) }
    }

    private func loadNow(_ p: MilkDropLibrary.Preset, smooth: Bool, blend: Double, why: String, attempt: Int = 0) {
        guard let lib, let pm else { return }
        loadFailure = nil
        if smooth { lib.setSoftCutDuration(pm, max(0.5, blend)) }
        let t0 = CACurrentMediaTime()
        p.url.path.withCString { lib.loadPresetFile(pm, $0, smooth) }
        lastLoadMs = (CACurrentMediaTime() - t0) * 1000
        if let f = loadFailure {
            onEvent?("milk:skip(failed) " + p.name + " — " + f)
            // remember it and move on (the sweep classifies instead of remembering)
            if sweep == nil {
                library.markBroken(p, reason: "load: " + f)
                if attempt < 5, let next = library.pick(loud: false) { loadNow(next, smooth: smooth, blend: blend, why: why, attempt: attempt + 1) }
            }
            return
        }
        lock.lock(); current = p; lock.unlock()
        framesSinceLoad = 0; lumaSamples = []
        onEvent?(String(format: "milk:loaded(%@) %@ [%.0f ms]", why, p.name, lastLoadMs))
    }

    /// "Skip broken": a preset that stays black for ~2 s while music plays is remembered and skipped.
    private func checkBlack(_ s: IOSurfaceRef, playing: Bool) {
        guard let p = current, framesSinceLoad >= 60, framesSinceLoad <= 180, framesSinceLoad % 15 == 0 else { return }
        guard playing else { lumaSamples = []; return }
        lumaSamples.append(Self.luma(s))
        guard framesSinceLoad == 180, lumaSamples.count >= 6 else { return }
        if lumaSamples.allSatisfy({ $0.mean < 0.012 && $0.peak < 0.08 }) {
            library.markBroken(p, reason: "renders black")
            onEvent?("milk:skip(black) " + p.name)
            if let next = library.pick(loud: false) { loadNow(next, smooth: false, blend: 0, why: "skip") }
        }
    }

    /// Mean and peak luminance (0..1) over a 48x27 grid of the surface (CPU read, no GPU stall: GL already finished).
    static func luma(_ s: IOSurfaceRef) -> (mean: Double, peak: Double) {
        IOSurfaceLock(s, .readOnly, nil); defer { IOSurfaceUnlock(s, .readOnly, nil) }
        let w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s)
        let base = IOSurfaceGetBaseAddress(s).assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, peak = 0.0, n = 0.0
        for gy in 0..<27 {
            let row = base + (gy * h / 27 + h / 54) * bpr
            for gx in 0..<48 {
                let px = row + (gx * w / 48 + w / 96) * 4
                let l = (0.114 * Double(px[0]) + 0.587 * Double(px[1]) + 0.299 * Double(px[2])) / 255
                sum += l; peak = max(peak, l); n += 1
            }
        }
        return (sum / n, peak)
    }

    /// PNG thumbnail of a surface (upright), for the sweep's contact sheets.
    static func writeThumb(_ s: IOSurfaceRef, to url: URL, width tw: Int = 480) {
        IOSurfaceLock(s, .readOnly, nil); defer { IOSurfaceUnlock(s, .readOnly, nil) }
        let w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let src = CGContext(data: IOSurfaceGetBaseAddress(s), width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info),
              let img = src.makeImage() else { return }
        let th = max(1, tw * h / max(1, w))
        guard let dst = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return }
        // GL rows are bottom-up: flip so the thumbnail is upright
        dst.translateBy(x: 0, y: CGFloat(th)); dst.scaleBy(x: 1, y: -1)
        dst.interpolationQuality = .medium
        dst.draw(img, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = dst.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Test harness: load presets back to back, give each `seconds`, classify ok / failed / black, save a thumbnail.
    struct Sweep {
        var list: [MilkDropLibrary.Preset]
        var seconds: Double
        var outDir: URL
        var index = -1
        var started = 0.0
        var samples: [(mean: Double, peak: Double)] = []
        var lines: [String] = []
        var ok = 0, failed = 0, black = 0
        var done = false

        init(list: [MilkDropLibrary.Preset], seconds: Double, outDir: URL) { self.list = list; self.seconds = seconds; self.outDir = outDir }

        /// Advance to the next preset when the current one has had its time. Returns false when finished.
        mutating func tick(_ r: MilkDropRenderer) -> Bool {
            let now = CACurrentMediaTime()
            if done { return false }
            if index >= 0 && now - started < seconds { return true }
            if index >= 0 && index < list.count && !(lines.count > index) { finish(r, failure: nil) }
            index += 1
            if index >= list.count { done = true; writeSummary(); return false }
            started = now; samples = []
            r.loadFailure = nil
            let p = list[index]
            r.loadNow(p, smooth: false, blend: 0, why: "sweep")
            if let f = r.loadFailure { finish(r, failure: f) }
            return true
        }
        mutating func observe(_ r: MilkDropRenderer, surface: IOSurfaceRef) {
            guard index >= 0, index < list.count, lines.count == index else { return }
            let age = CACurrentMediaTime() - started
            if age > seconds * 0.5 && r.framesSinceLoad % 6 == 0 { samples.append(MilkDropRenderer.luma(surface)) }
            if age > seconds - 0.12 && samples.count >= 3 {
                MilkDropRenderer.writeThumb(surface, to: outDir.appendingPathComponent(String(format: "sweep_%04d.png", index)))
                finish(r, failure: nil)
            }
        }
        private mutating func finish(_ r: MilkDropRenderer, failure: String?) {
            let p = list[index]
            let isBlack = failure == nil && !samples.isEmpty && samples.allSatisfy { $0.mean < 0.012 && $0.peak < 0.08 }
            let status = failure != nil ? "failed" : isBlack ? "black" : "ok"
            if status == "ok" { ok += 1 } else if status == "failed" { failed += 1 } else { black += 1 }
            let mean = samples.isEmpty ? 0 : samples.map { $0.mean }.reduce(0, +) / Double(samples.count)
            let line = String(format: "%04d\t%@\t%.4f\t%.0f\t%@\t%@", index, status, mean, r.lastLoadMs, p.key, failure ?? "")
            lines.append(line)
            r.onEvent?("milk:sweep " + line)
        }
        private func writeSummary() {
            let head = "index\tstatus\tmean_luma\tload_ms\tpreset\terror\n"
            try? (head + lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("sweep.tsv"), atomically: true, encoding: .utf8)
            let s = "presets \(list.count) ok \(ok) failed \(failed) black \(black)\n"
            try? s.write(to: outDir.appendingPathComponent("sweep_summary.txt"), atomically: true, encoding: .utf8)
            NSLog("RAVE LIVE: MilkDrop sweep done: %@", s)
        }
    }
}

let milkDropShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct MO { float4 pos [[position]]; float2 uv; };
vertex MO mvert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    MO o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o;
}
// u: 0 has frame, 1 time, 2 kick, 3 build, 4 drop, 5 blinder, 6 fade, 7 blackout, 8 aspect
fragment float4 mfrag(MO in [[stage_in]], texture2d<float> t [[texture(0)]], constant float* u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    // beat-locked punch: a small zoom on the kick, a slow creep in during a build
    float zoom = 1.0 - 0.022 * u[2] - 0.035 * u[3];
    uv = (uv - 0.5) * zoom + 0.5;
    float3 c;
    if (u[0] > 0.5) {
        c = t.sample(s, float2(uv.x, 1.0 - uv.y)).rgb;    // GL rows are bottom-up
    } else {
        float2 q = (in.uv - 0.5) * float2(u[8], 1.0);
        float r = length(q);
        c = float3(0.05, 0.03, 0.09) + 0.05 * float3(0.6 + 0.4 * sin(u[1] * 0.4), 0.3, 0.8) * (1.0 - r);
    }
    float l = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l), c, 1.0 + 0.45 * u[3]);              // builds get more saturated
    c *= 1.0 + 0.16 * u[2];                                 // kick lift
    c += u[5] * 0.3;                                        // blinder (already passed the strobe limiter)
    c *= mix(0.35, 1.0, u[6]);
    if (u[7] > 0.5) c = float3(0);
    return float4(max(c, 0.0), 1);
}
"""
