// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Metal
import QuartzCore
import MetalKit

/// Visuals-only mode renderer: ping-pong feedback textures + composite.
final class VisualsRenderer {
    static let presetNames = ["Ambience", "Scope", "Tunnel", "MilkWarp", "Kaleido", "Bars", "Starburst", "Plasma", "Fractal", "Wormhole", "Chrome", "Synthwave", "Crystals", "Truchet", "Waterfall", "Galaxy", "Mandala", "Lissajous", "Sphere", "Northern Lights", "Nebula", "Glyph Rain", "Hyperdrive",
                                "Ink Water", "Neon City", "Laser Grid", "Terrain", "Portal", "Flower", "Coral", "Pond", "Fireworks", "Silk"]
    static var count: Int { presetNames.count }
    /// Pointer input (mouse + camera hands), normalised 0..1 with a top-left origin, handed to the visuals shader.
    struct Pointer { var pos: SIMD2<Float>; var vel: SIMD2<Float>; var strength: Float }   // vel in 0..1 units per second; strength 0.5 hover, 1 drag/hand
    struct Input { var pointers: [Pointer] = []; var clicks: [(pos: SIMD2<Float>, age: Float)] = [] }
    /// Presets whose state lives in a small simulation texture (reaction-diffusion, wave equation).
    static let simPresets: Set<Int> = [29, 30]
    let warp: MTLRenderPipelineState
    let sim: MTLRenderPipelineState
    let comp: MTLRenderPipelineState
    let device: MTLDevice
    private var tex: [MTLTexture] = []
    private var cur = 0
    private var peaks = [Float](repeating: 0, count: 128)
    var v = [Float](repeating: 0, count: 56)
    private var simTex: [MTLTexture] = []
    private var simCur = 0
    private var lastSimPreset = -1
    private var warmLeft = 0
    static let simW = 640, simH = 360

    var preset = 0
    var variation: Float = 0.3
    var paletteIndex = 0
    var autoCycle = true
    private var lastLook: Float = -1
    private var rng: UInt64 = 0xC0FFEE

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
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
    }

    /// Phrase changes (the director picks a new look) advance the preset; drops jump to a big one.
    private var lastChange = -100.0
    private var holdUntil = 0.0
    /// Hold each preset >= 6 s (12 s after a drop) so phrase changes right after a switch don't flicker.
    func direct(look: Float, dropStarted: Bool, now: Double = CACurrentMediaTime()) {
        guard autoCycle else { lastLook = look; return }
        if dropStarted {
            preset = nextFromBag(prefer: [0, 8, 9, 10, 11, 18, 20, 22, 25, 27, 31]); newVariant(); lastChange = now; holdUntil = now + 12
        } else if look != lastLook && lastLook >= 0 && now >= holdUntil && now - lastChange >= 6 {
            preset = nextFromBag(); newVariant(); lastChange = now
        }
        lastLook = look
    }
    /// Shuffle bag: every preset plays once before any repeats (and never the same one twice in a row).
    private var bag: [Int] = []
    func nextFromBag(prefer: [Int]? = nil) -> Int {
        if bag.isEmpty {
            bag = Array(0..<Self.count).shuffled(using: &gen)
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
        if tex.first?.width != w || tex.first?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            tex = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
            // clear both once
            for t in tex {
                let c = MTLRenderPassDescriptor()
                c.colorAttachments[0].texture = t; c.colorAttachments[0].loadAction = .clear
                c.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); c.colorAttachments[0].storeAction = .store
                cb.makeRenderCommandEncoder(descriptor: c)?.endEncoding()
            }
        }
        guard tex.count == 2 else { return }
        for i in 0..<128 { peaks[i] = max(s.spectrum[i], peaks[i] - dt * 0.35) }

        // uniforms (shared show state from the stage renderer's u[] slots)
        v[0] = Float(w); v[1] = Float(h); v[2] = u[2]; v[3] = u[3]
        v[4] = 0.5 * (s.bands[0] + s.bands[1]); v[5] = s.bands[3]; v[6] = s.bands[4]
        v[7] = u[9]; v[8] = u[12]; v[9] = u[13]; v[10] = u[25]; v[11] = Float(preset)
        v[12] = u[17]; v[13] = u[14]; v[14] = u[16]; v[15] = u[2] * 0.04 + floor(u[25] / 16) * 0.13
        v[16] = u[15]; v[17] = u[10]; v[18] = variation; v[19] = Float(paletteIndex); v[20] = dt * 60

        // pointer slots: v[21] count, v[22+5i] x y vx vy strength (i<3, p-space), v[37+3i] x y age (i<4); v[53] sim reset
        let aspect = Float(w) / Float(h)
        for i in 21..<56 { v[i] = 0 }
        v[21] = Float(min(3, input.pointers.count))
        for (i, pt) in input.pointers.prefix(3).enumerated() {
            let b = 22 + 5 * i
            v[b] = (pt.pos.x * 2 - 1) * aspect; v[b + 1] = 1 - pt.pos.y * 2
            v[b + 2] = pt.vel.x * 2 * aspect; v[b + 3] = -pt.vel.y * 2; v[b + 4] = pt.strength
        }
        v[54] = u[37]                                   // beat clock (beats), see Renderer u[37]
        for i in 0..<4 {
            let b = 37 + 3 * i
            if i < input.clicks.count {
                let c = input.clicks[i]
                v[b] = (c.pos.x * 2 - 1) * aspect; v[b + 1] = 1 - c.pos.y * 2; v[b + 2] = c.age
            } else { v[b + 2] = 99 }
        }
        if Self.simPresets.contains(preset) { encodeSim(cb: cb, dt: dt) } else { lastSimPreset = -1 }

        let prev = tex[cur], dst = tex[1 - cur]
        let p1 = MTLRenderPassDescriptor()
        p1.colorAttachments[0].texture = dst; p1.colorAttachments[0].loadAction = .dontCare; p1.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: p1) {
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
        cur = 1 - cur
    }

    /// Advance the small simulation texture (Coral = Gray-Scott, Pond = 2D wave equation) a few sub-steps per frame.
    private func encodeSim(cb: MTLCommandBuffer, dt: Float) {
        if simTex.count != 2 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.simW, height: Self.simH, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            simTex = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
            lastSimPreset = -1
        }
        guard simTex.count == 2 else { return }
        let reset = lastSimPreset != preset
        lastSimPreset = preset
        let k: Float = preset == 29 ? 6 : 4                   // sub-steps per 60 Hz frame
        let n = max(1, min(10, Int((dt * 60 * k).rounded())))
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
        v[53] = 0
    }
}
