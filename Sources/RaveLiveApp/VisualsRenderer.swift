// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Metal
import QuartzCore
import MetalKit
import simd

/// Visuals-only mode renderer: ping-pong feedback textures + composite.
final class VisualsRenderer {
    static let builtinNames = ["Ambience", "Scope", "Tunnel", "MilkWarp", "Kaleido", "Bars", "Starburst", "Plasma", "Fractal", "Wormhole", "Chrome", "Synthwave", "Crystals", "Truchet", "Waterfall", "Galaxy", "Mandala", "Lissajous", "Sphere", "Northern Lights", "Nebula", "Glyph Rain", "Hyperdrive",
                                "Ink Water", "Neon City", "Laser Grid", "Terrain", "Portal", "Flower", "Coral", "Pond", "Fireworks", "Silk",
                                "Datamosh", "Julia", "Rain Glass", "Kick Cubes", "String Art", "Fireflies", "Life", "Subwoofer", "Moire", "XY Scope",
                                "Dancefloor", "Disco Ball", "Laser Show", "Gravity Grid", "Vinyl"]
    /// Built-ins, then Shader Lab user shaders ("Lab: <file name>") in folder order.
    static var presetNames: [String] { builtinNames + UserShaderLibrary.shared.entries.map { "Lab: " + $0.name } }
    static var count: Int { presetNames.count }
    /// SHOW / drop picks: big, punchy presets vs calm ones (every built-in is in exactly one list).
    static let loudPresets = [0, 2, 6, 8, 9, 10, 11, 12, 13, 18, 20, 22, 24, 25, 27, 31, 33, 36, 40, 43, 44, 45]
    static let calmPresets = [1, 3, 7, 14, 15, 16, 17, 19, 21, 23, 26, 28, 29, 30, 32, 34, 35, 37, 38, 39, 41, 42, 46, 47]
    var currentName: String { let n = Self.presetNames; return n.indices.contains(preset) ? n[preset] : n[0] }
    /// Index into the Shader Lab list when a user shader is selected, else nil.
    var userIndex: Int? { preset >= Self.builtinNames.count ? preset - Self.builtinNames.count : nil }
    let lab = PresetLab()
    /// Pointer input (mouse + camera hands), normalised 0..1 with a top-left origin, handed to the visuals shader.
    struct Pointer { var pos: SIMD2<Float>; var vel: SIMD2<Float>; var strength: Float }   // vel in 0..1 units per second; strength 0.5 hover, 1 drag/hand
    struct Input { var pointers: [Pointer] = []; var clicks: [(pos: SIMD2<Float>, age: Float)] = [] }
    /// Presets whose state lives in a small simulation texture (reaction-diffusion, wave equation).
    static let simPresets: Set<Int> = [29, 30, 39]
    let warp: MTLRenderPipelineState
    let sim: MTLRenderPipelineState
    let comp: MTLRenderPipelineState
    let device: MTLDevice
    /// Two feedback slots so two presets can run at once during a crossfade (Classic preset changes). Each slot is
    /// cleared when a preset starts in it or after it sat unused, so a preset never opens on another preset's old frame.
    private var texSets: [[MTLTexture]] = [[], []]
    private var curs = [0, 0]
    private var slotPreset = [-1, -1]
    private var slotLastUse = [-100.0, -100.0]
    var slot = 0
    private var peaks = [Float](repeating: 0, count: 128)
    var v = [Float](repeating: 0, count: 64)
    private var simTex: [MTLTexture] = []
    private var simCur = 0
    private var lastSimPreset = -1
    private var warmLeft = 0
    static let simW = 640, simH = 360
    static func simSize(_ p: Int) -> (Int, Int) { p == 39 ? (128, 72) : (simW, simH) }
    private var lastLifeBeat: Float = -1
    // per-preset state that has to live on the CPU: Vinyl scratching, Fireflies' smoothed pull toward the pointer
    private var scratch: Float = 0, scratching = false, lastScratchAngle: Float = 0, lastBase: Float = 0
    private var attract: Float = 0, attractPos = SIMD2<Float>(0, 0)
    private var labTime: Float = -1, lastU2: Float = -1
    private let pixelFormat: MTLPixelFormat
    // Shader Lab: spectrum (512 texels, interpolated from the 128-band log spectrum) + waveform textures, 3 in flight
    private var userTex: [(MTLTexture, MTLTexture)] = []
    private var userTexI = 0
    private var userFrame: Float = 0

    var preset = 0
    var variation: Float = 0.3
    var paletteIndex = 0
    var autoCycle = true
    private var lastLook: Float = -1
    private var rng: UInt64 = 0xC0FFEE

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        self.pixelFormat = pixelFormat
        do {
            let lib = try device.makeLibrary(source: visualsShaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vvert")
            d.fragmentFunction = lib.makeFunction(name: "vwarp")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            warp = try device.makeRenderPipelineState(descriptor: d)
            d.fragmentFunction = lib.makeFunction(name: "vsim")
            sim = try device.makeRenderPipelineState(descriptor: d)
            d.fragmentFunction = lib.makeFunction(name: "vcomp")
            d.colorAttachments[0].pixelFormat = pixelFormat
            comp = try device.makeRenderPipelineState(descriptor: d)
        } catch { NSLog("Visuals shader error: \(error)"); return nil }
        lab.visuals = self
        UserShaderLibrary.shared.device = device
        DispatchQueue.main.async { [weak self] in self?.lab.applyCommandLine() }
    }

    /// Phrase changes (the director picks a new look) advance the preset; drops jump to a big one.
    private var lastChange = -100.0
    private var holdUntil = 0.0
    /// Hold each preset >= 6 s (12 s after a drop) so phrase changes right after a switch don't flicker.
    func direct(look: Float, dropStarted: Bool, now: Double = CACurrentMediaTime()) {
        guard autoCycle else { lastLook = look; return }
        if dropStarted {
            preset = nextFromBag(prefer: [0, 8, 9, 10, 11, 18, 20, 22, 25, 27, 31, 36, 40, 43, 44, 45]); newVariant(); lastChange = now; holdUntil = now + 12
        } else if look != lastLook && lastLook >= 0 && now >= holdUntil && now - lastChange >= 6 {
            preset = nextFromBag(); newVariant(); lastChange = now
        }
        lastLook = look
    }
    /// Shuffle bag: every built-in plays once before any repeats (and never the same one twice in a row). Shader Lab
    /// shaders are picked by hand ([ ] keys) and never auto-played, so a half-finished shader can't land in a set.
    private var bag: [Int] = []
    func nextFromBag(prefer: [Int]? = nil) -> Int {
        if bag.isEmpty {
            bag = Array(0..<Self.builtinNames.count).shuffled(using: &gen)
            if bag.last == preset { bag.swapAt(0, bag.count - 1) }
        }
        if let pref = prefer, let i = bag.lastIndex(where: { pref.contains($0) }) { return bag.remove(at: i) }
        return bag.removeLast()
    }
    /// Give a visit its own palette + variation so a preset never looks identical twice.
    func newVariant() { paletteIndex = next(7); variation = Float(next(1000)) / 1000 }
    private var gen = SystemRandomNumberGenerator()
    private func next(_ n: Int) -> Int { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Int(rng % UInt64(n)) }

    func encode(cb: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, size: CGSize, dt: Float,
                s: AudioSnapshot, u: [Float], input: Input = Input()) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let sl = slot, now = CACurrentMediaTime()
        var stale = slotPreset[sl] != preset || now - slotLastUse[sl] > 0.25
        if texSets[sl].first?.width != w || texSets[sl].first?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            texSets[sl] = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
            stale = true
        }
        slotPreset[sl] = preset; slotLastUse[sl] = now
        let tex = texSets[sl]
        guard tex.count == 2 else { return }
        if stale {             // fresh start: no feedback garbage from an earlier preset or visit
            for t in tex {
                let c = MTLRenderPassDescriptor()
                c.colorAttachments[0].texture = t; c.colorAttachments[0].loadAction = .clear
                c.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); c.colorAttachments[0].storeAction = .store
                cb.makeRenderCommandEncoder(descriptor: c)?.endEncoding()
            }
            if Self.simPresets.contains(preset) { lastSimPreset = -1 }
        }
        let cur = curs[sl]
        for i in 0..<128 { peaks[i] = max(s.spectrum[i], peaks[i] - dt * 0.35) }

        lab.drainPending()
        if preset >= Self.count { preset = 0 }          // a Shader Lab file was deleted while selected
        let tw = lab.tweak(for: currentName)
        if u[2] != lastU2 {                              // own clock so the Speed tweak never jumps (once per drawn frame, even inside SHOW transitions)
            labTime = labTime < 0 ? u[2] : labTime + (lastU2 < 0 ? 0 : (u[2] - lastU2)) * tw.speed
            lastU2 = u[2]
        }

        // uniforms (shared show state from the stage renderer's u[] slots)
        let br = tw.beat
        v[0] = Float(w); v[1] = Float(h); v[2] = labTime; v[3] = u[3]
        v[4] = 0.5 * (s.bands[0] + s.bands[1]); v[5] = s.bands[3]; v[6] = s.bands[4]
        v[7] = u[9] * br; v[8] = min(1.5, u[12] * br); v[9] = u[13]; v[10] = u[25]; v[11] = Float(preset)
        v[12] = u[17]; v[13] = u[14]; v[14] = u[16]; v[15] = u[2] * 0.04 + floor(u[25] / 16) * 0.13 + tw.hueShift
        v[16] = u[15]; v[17] = u[10] * br; v[18] = variation; v[19] = Float(tw.palette >= 0 ? tw.palette : paletteIndex); v[20] = dt * 60

        // pointer slots: v[21] count, v[22+5i] x y vx vy strength (i<3, p-space), v[37+3i] x y age (i<4); v[53] sim reset
        let aspect = Float(w) / Float(h)
        for i in 21..<64 { v[i] = 0 }
        v[21] = Float(min(3, input.pointers.count))
        for (i, pt) in input.pointers.prefix(3).enumerated() {
            let b = 22 + 5 * i
            v[b] = (pt.pos.x * 2 - 1) * aspect; v[b + 1] = 1 - pt.pos.y * 2
            v[b + 2] = pt.vel.x * 2 * aspect; v[b + 3] = -pt.vel.y * 2; v[b + 4] = pt.strength
        }
        v[54] = u[37] * tw.speed                        // beat clock (beats), see Renderer u[37]; speed tweak is 0.25/0.5/1/2 so beats stay on beats
        for i in 0..<4 {
            let b = 37 + 3 * i
            if i < input.clicks.count {
                let c = input.clicks[i]
                v[b] = (c.pos.x * 2 - 1) * aspect; v[b + 1] = 1 - c.pos.y * 2; v[b + 2] = c.age
            } else { v[b + 2] = 99 }
        }
        v[56] = tw.density; v[57] = tw.feedback; v[58] = Float(tw.symmetry)
        updatePresetState(dt: dt, input: input)
        if Self.simPresets.contains(preset) { encodeSim(cb: cb, dt: dt) } else { lastSimPreset = -1 }

        let prev = tex[cur], dst = tex[1 - cur]
        let p1 = MTLRenderPassDescriptor()
        p1.colorAttachments[0].texture = dst; p1.colorAttachments[0].loadAction = .dontCare; p1.colorAttachments[0].storeAction = .store
        if let ui = userIndex {
            encodeUser(cb: cb, pass: p1, prev: prev, index: ui, s: s, u: u, dt: dt)
            v[11] = -1                                   // composite shows user shaders as written
        } else if let e = cb.makeRenderCommandEncoder(descriptor: p1) {
            e.setRenderPipelineState(warp)
            e.setFragmentBytes(v, length: v.count * 4, index: 0)
            e.setFragmentBytes(s.waveform, length: 512 * 4, index: 1)
            e.setFragmentBytes(s.spectrum, length: 128 * 4, index: 2)
            e.setFragmentBytes(peaks, length: 128 * 4, index: 3)
            e.setFragmentTexture(prev, index: 0)
            e.setFragmentTexture(simTex.count == 2 ? simTex[simCur] : prev, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        if let e = cb.makeRenderCommandEncoder(descriptor: rpd) {
            e.setRenderPipelineState(comp)
            e.setFragmentBytes(v, length: v.count * 4, index: 0)
            e.setFragmentTexture(dst, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        curs[sl] = 1 - cur
    }

    /// CPU-side state for presets that need memory: Vinyl's scratch offset, Fireflies' smoothed pull toward the pointer.
    private func updatePresetState(dt: Float, input: Input) {
        let strong = (0..<Int(v[21])).first { v[26 + 5 * $0] >= 0.9 }
        if preset == 47 {
            let base = v[54] * 0.25                      // a quarter turn per beat (~32 rpm at 128 BPM)
            let c = SIMD2<Float>(-0.15, 0)               // record centre in p-space (see vinyl() in VisualsShader)
            if let i = strong, simd_length(SIMD2(v[22 + 5 * i], v[23 + 5 * i]) - c) < 0.95 || scratching && strong != nil {
                let q = SIMD2(v[22 + 5 * i], v[23 + 5 * i]) - c
                let ang = atan2f(q.y, q.x)
                if scratching {
                    var d = ang - lastScratchAngle
                    if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                    scratch -= d / (2 * .pi) + (base - lastBase)          // the record sticks to the hand
                }
                lastScratchAngle = ang; scratching = true
            } else {
                scratching = false
                scratch -= scratch.rounded()                              // ease back to the nearest beat-locked position
                scratch -= scratch * min(1, dt * 1.6)
            }
            lastBase = base
            v[59] = base + scratch
        }
        if preset == 38 {
            let any = (0..<Int(v[21])).first { v[26 + 5 * $0] > 0.3 }
            attract += ((any != nil ? 1 : 0) - attract) * min(1, dt * 0.9)
            if let i = any { attractPos += (SIMD2(v[22 + 5 * i], v[23 + 5 * i]) - attractPos) * min(1, dt * 2.5) }
            v[60] = attract; v[61] = attractPos.x; v[62] = attractPos.y
        }
    }

    /// Shader Lab pass: the user's fragment writes the feedback texture (so `previous()` is its own last frame).
    private func encodeUser(cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, prev: MTLTexture, index: Int, s: AudioSnapshot, u: [Float], dt: Float) {
        let lib = UserShaderLibrary.shared
        guard index < lib.entries.count, let pso = lib.entries[index].pipeline else {
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.01, 0.03, 1)
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            return
        }
        if userTex.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 512, height: 1, mipmapped: false)
            d.usage = [.shaderRead]
            userTex = (0..<3).compactMap { _ in
                guard let a = device.makeTexture(descriptor: d), let b = device.makeTexture(descriptor: d) else { return nil }
                return (a, b)
            }
        }
        guard !userTex.isEmpty else { return }
        userTexI = (userTexI + 1) % userTex.count
        let (st, wt) = userTex[userTexI]
        var spec512 = [Float](repeating: 0, count: 512)
        for i in 0..<512 {
            let f = Float(i) / 511 * 127, i0 = min(126, Int(f)), t = f - Float(i0)
            spec512[i] = s.spectrum[i0] * (1 - t) + s.spectrum[i0 + 1] * t
        }
        st.replace(region: MTLRegionMake2D(0, 0, 512, 1), mipmapLevel: 0, withBytes: spec512, bytesPerRow: 512 * 4)
        wt.replace(region: MTLRegionMake2D(0, 0, 512, 1), mipmapLevel: 0, withBytes: s.waveform, bytesPerRow: 512 * 4)
        userFrame += 1
        var U = [Float](repeating: 0, count: UserShaderLibrary.uniformCount)
        let tb = v[54]
        U[0] = v[0]; U[1] = v[1]; U[2] = v[2]; U[3] = dt; U[4] = tb; U[5] = tb - floor(tb); U[6] = tb / 4 - floor(tb / 4); U[7] = Float(s.bpm)
        U[8] = v[4]; U[9] = v[5]; U[10] = v[6]; U[11] = u[3]; U[12] = v[7]; U[13] = v[17]; U[14] = u[11]
        U[15] = u[34]; U[16] = u[17]; U[17] = userFrame; U[18] = v[15]; U[19] = variation; U[20] = v[21]
        for i in 0..<3 { U[21 + 3 * i] = v[22 + 5 * i]; U[22 + 3 * i] = v[23 + 5 * i]; U[23 + 3 * i] = v[26 + 5 * i] }
        U[30] = v[37]; U[31] = v[38]; U[32] = v[39]
        guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(pso)
        e.setFragmentBytes(U, length: U.count * 4, index: 0)
        e.setFragmentTexture(st, index: 0); e.setFragmentTexture(wt, index: 1); e.setFragmentTexture(prev, index: 2)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    /// Advance the small simulation texture (Coral = Gray-Scott, Pond = 2D wave equation) a few sub-steps per frame.
    private func encodeSim(cb: MTLCommandBuffer, dt: Float) {
        let (sw, sh) = Self.simSize(preset)
        if simTex.count != 2 || simTex[0].width != sw || simTex[0].height != sh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: sw, height: sh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            simTex = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
            lastSimPreset = -1
        }
        guard simTex.count == 2 else { return }
        let reset = lastSimPreset != preset
        lastSimPreset = preset
        let k: Float = preset == 29 ? 6 : 4                   // sub-steps per 60 Hz frame
        var n = max(1, min(10, Int((dt * 60 * k).rounded())))
        if preset == 39 {                                     // Life: one paint pass per frame; a generation ticks when the beat clock crosses a beat
            n = 1
            let b = floor(v[54])
            v[55] = (b != lastLifeBeat && lastLifeBeat >= 0 && !reset) ? 1 : 0
            lastLifeBeat = b
        }
        if reset { warmLeft = preset == 29 ? 60 : 0 }
        let steps = warmLeft > 0 ? n + 60 : n                 // Coral opens as a quick time-lapse of growth (~0.7 s), then settles to normal speed
        warmLeft -= 1
        for i in 0..<steps {
            v[53] = (reset && i == 0) ? 1 : 0
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = simTex[1 - simCur]; p.colorAttachments[0].loadAction = .dontCare; p.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: p) else { return }
            e.setRenderPipelineState(sim)
            e.setFragmentBytes(v, length: v.count * 4, index: 0)
            e.setFragmentTexture(simTex[simCur], index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
            simCur = 1 - simCur
        }
        v[53] = 0; v[55] = 0
    }
}
