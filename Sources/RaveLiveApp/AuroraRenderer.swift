// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore

/// AURORA: fluid + particles + bloom. Audio events and hands/mouse inject force and dye.
final class AuroraRenderer {
    struct Splat { var pos: SIMD2<Float>; var force: SIMD2<Float>; var color: SIMD4<Float>; var radius: Float; var p1: Float = 0, p2: Float = 0, p3: Float = 0 }

    let device: MTLDevice
    private var pAdvect, pSplat, pMask, pCurl, pVort, pDiv, pPress, pScale, pGrad, pParticles: MTLComputePipelineState
    private let pDraw: MTLRenderPipelineState, pDye: MTLRenderPipelineState, pFinal: MTLRenderPipelineState
    private var vel: [MTLTexture] = [], dye: [MTLTexture] = [], prs: [MTLTexture] = []
    private var curl: MTLTexture!, div: MTLTexture!
    private var hdr: MTLTexture?, half: MTLTexture?, bloomA: MTLTexture?, bloomB: MTLTexture?
    private var mask: MTLTexture
    private let particleBuf: MTLBuffer
    let particleCount: Int
    var fullBloom = true             // false on the Low quality tier: one blur radius instead of two
    private var simW = 256, simH = 144
    private var t: Float = 0
    private var rng: UInt64 = 0xA11CE
    private var lastBeat: Float = -1
    private var hue: Float = 0.6
    private var pu = [Float](repeating: 0, count: 52)

    // interaction (uv space, y down)
    struct Pointer { var pos: SIMD2<Float>; var vel: SIMD2<Float>; var down: Bool; var burst: Bool }
    var pointers: [Pointer] = []
    var maskActive = false
    var curlStrength: Float = 28
    var symmetry = 0
    /// New look for a SHOW visit: colour family + symmetry + swirl character.
    func newVariant(seed: Int) {
        hue = Float(seed % 7) * 0.143 + rand() * 0.1
        symmetry = [0, 0, 1, 2, 3][seed % 5]
        curlStrength = [18, 28, 40][seed % 3]
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, particles: Int) {
        self.device = device
        particleCount = particles
        do {
            let lib = try device.makeLibrary(source: auroraShaderSource, options: nil)
            func k(_ n: String) throws -> MTLComputePipelineState { try device.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
            pAdvect = try k("advect"); pSplat = try k("splat"); pMask = try k("maskInject"); pCurl = try k("curlK")
            pVort = try k("vorticity"); pDiv = try k("divergence"); pPress = try k("pressureK"); pScale = try k("scaleK")
            pGrad = try k("gradient"); pParticles = try k("particles")
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "pvert"); d.fragmentFunction = lib.makeFunction(name: "pfrag")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].rgbBlendOperation = .add; d.colorAttachments[0].alphaBlendOperation = .add
            d.colorAttachments[0].sourceRGBBlendFactor = .one; d.colorAttachments[0].destinationRGBBlendFactor = .one
            d.colorAttachments[0].sourceAlphaBlendFactor = .one; d.colorAttachments[0].destinationAlphaBlendFactor = .one
            pDraw = try device.makeRenderPipelineState(descriptor: d)
            let d2 = MTLRenderPipelineDescriptor()
            d2.vertexFunction = lib.makeFunction(name: "fsv"); d2.fragmentFunction = lib.makeFunction(name: "dyeToHDR")
            d2.colorAttachments[0].pixelFormat = .rgba16Float
            pDye = try device.makeRenderPipelineState(descriptor: d2)
            d2.fragmentFunction = lib.makeFunction(name: "finalComp"); d2.colorAttachments[0].pixelFormat = pixelFormat
            pFinal = try device.makeRenderPipelineState(descriptor: d2)
        } catch { NSLog("Aurora shader error: \(error)"); return nil }
        guard let buf = device.makeBuffer(length: particles * 32, options: .storageModeShared) else { return nil }
        particleBuf = buf
        let ptr = buf.contents().bindMemory(to: Float.self, capacity: particles * 8)
        var r: UInt64 = 12345
        func rnd() -> Float { r = r &* 6364136223846793005 &+ 1442695040888963407; return Float(r >> 40) / Float(1 << 24) }
        for i in 0..<particles {
            ptr[i * 8 + 0] = rnd(); ptr[i * 8 + 1] = rnd(); ptr[i * 8 + 2] = 0; ptr[i * 8 + 3] = 0
            let life = 0.5 + 5 * rnd()
            ptr[i * 8 + 4] = life; ptr[i * 8 + 5] = life; ptr[i * 8 + 6] = rnd(); ptr[i * 8 + 7] = rnd() * 100
        }
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 256, height: 144, mipmapped: false)
        md.usage = [.shaderRead]
        mask = device.makeTexture(descriptor: md)!
    }

    /// Body mask from the camera (256x144 bytes, top-left origin, already mirrored).
    func updateMask(_ bytes: [UInt8]) {
        guard bytes.count == 256 * 144 else { return }
        mask.replace(region: MTLRegionMake2D(0, 0, 256, 144), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256)
    }

    private func tex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, rt: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.usage = rt ? [.renderTarget, .shaderRead, .shaderWrite] : [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func ensure(_ size: CGSize) {
        let w = max(16, Int(size.width)), h = max(16, Int(size.height))
        if hdr?.width == w && hdr?.height == h { return }
        let aspect = Double(w) / Double(h)
        simH = 144; simW = Int((144 * aspect).rounded())
        let dh = min(h, 720), dw = Int((Double(dh) * aspect).rounded())
        vel = [tex(.rg32Float, simW, simH), tex(.rg32Float, simW, simH)]
        prs = [tex(.r32Float, simW, simH), tex(.r32Float, simW, simH)]
        curl = tex(.r32Float, simW, simH); div = tex(.r32Float, simW, simH)
        dye = [tex(.rgba16Float, dw, dh), tex(.rgba16Float, dw, dh)]
        hdr = tex(.rgba16Float, w, h, rt: true)
        half = tex(.rgba16Float, w / 2, h / 2); bloomA = tex(.rgba16Float, w / 2, h / 2); bloomB = tex(.rgba16Float, w / 2, h / 2)
    }

    private func rand() -> Float { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Float(rng >> 40) / Float(1 << 24) }
    private func color(_ h: Float, _ k: Float) -> SIMD4<Float> {
        let c = SIMD3<Float>(0.5 + 0.5 * cos(6.28318 * (h + 0.0)), 0.5 + 0.5 * cos(6.28318 * (h + 0.33)), 0.5 + 0.5 * cos(6.28318 * (h + 0.67)))
        return SIMD4<Float>(c * k, 1)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
        enc.setComputePipelineState(p)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    func encode(cb: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, size: CGSize, dt dtIn: Float, s: AudioSnapshot,
                u: [Float], newKick: Bool, newHat: Bool, dropStarted: Bool, strobe: Float, blackout: Bool, fade: Float) {
        ensure(size)
        guard let hdr, let half, let bloomA, let bloomB else { return }
        let dt = min(dtIn, 1.0 / 30)
        t += dt
        let aspect = Float(size.width / size.height)
        let energy = u[3], beatIdx = u[25], bass = 0.5 * (s.bands[0] + s.bands[1]), build = u[34]
        hue += dt * 0.01
        if beatIdx != lastBeat && Int(beatIdx) % 16 == 0 && lastBeat >= 0 { hue += 0.17 }   // new phrase, new colours
        lastBeat = beatIdx

        // ---- splats from the music
        var vs: [Splat] = [], ds: [Splat] = []
        let live = fade > 0.05
        if live && newKick {
            let n = energy > 0.7 ? 3 : 1
            for k in 0..<n {
                let a = (beatIdx * 2.39996 + Float(k) * 2.1) .truncatingRemainder(dividingBy: 6.28318)
                let r: Float = 0.12 + 0.18 * rand()
                let pos = SIMD2<Float>(0.5 + cos(a) * r / aspect, 0.5 + sin(a) * r)
                let dir = SIMD2<Float>(cos(a), sin(a))
                let f = (900 + 2600 * energy) * dir
                vs.append(Splat(pos: pos, force: f, color: .zero, radius: 0.0012 + 0.002 * energy))
                ds.append(Splat(pos: pos, force: .zero, color: color(hue + Float(k) * 0.12 + rand() * 0.1, 0.25 + 0.3 * energy), radius: 0.0016 + 0.002 * energy))
            }
        }
        if live && bass > 0.25 {         // twin vortices that breathe with the bass
            for sgn: Float in [-1, 1] {
                let a = t * 0.4 * sgn
                let pos = SIMD2<Float>(0.5 + sgn * 0.17 / aspect * cos(a), 0.5 + 0.17 * sin(a))
                let tang = SIMD2<Float>(-sin(a), cos(a)) * sgn
                vs.append(Splat(pos: pos, force: tang * 260 * bass, color: .zero, radius: 0.004))
                ds.append(Splat(pos: pos, force: .zero, color: color(hue + 0.5 + sgn * 0.08, 0.05 * bass), radius: 0.003))
            }
        }
        if live && newHat && s.bands[4] > 0.3 {
            let pos = SIMD2<Float>(rand(), rand())
            ds.append(Splat(pos: pos, force: .zero, color: SIMD4<Float>(0.35, 0.35, 0.4, 1), radius: 0.0003))
            vs.append(Splat(pos: pos, force: SIMD2<Float>(rand() - 0.5, rand() - 0.5) * 900, color: .zero, radius: 0.0004))
        }
        if dropStarted {                 // shockwave
            for k in 0..<14 {
                let a = Float(k) / 14 * 6.28318
                let pos = SIMD2<Float>(0.5 + cos(a) * 0.08 / aspect, 0.5 + sin(a) * 0.08)
                vs.append(Splat(pos: pos, force: SIMD2<Float>(cos(a), sin(a)) * 5200, color: .zero, radius: 0.002))
                ds.append(Splat(pos: pos, force: .zero, color: color(hue + Float(k) / 14, 0.7), radius: 0.0025))
            }
            hue += 0.33
        }
        if !live {                       // idle: slow ambient wisps
            if rand() < 0.03 {
                let pos = SIMD2<Float>(rand(), rand())
                vs.append(Splat(pos: pos, force: SIMD2<Float>(rand() - 0.5, rand() - 0.5) * 300, color: .zero, radius: 0.003))
                ds.append(Splat(pos: pos, force: .zero, color: color(hue + rand() * 0.3, 0.12), radius: 0.003))
            }
        }
        // ---- hands / mouse
        var emitters: [SIMD4<Float>] = []
        for p in pointers {
            let speed = simd_length(p.vel)
            if p.down || speed > 0.05 {
                vs.append(Splat(pos: p.pos, force: p.vel * 5200, color: .zero, radius: 0.0015))
                ds.append(Splat(pos: p.pos, force: .zero, color: color(hue + 0.1 + p.pos.x * 0.3, 0.12 + min(0.6, speed * 0.8)), radius: 0.0012))
            }
            if p.burst {
                for k in 0..<10 {
                    let a = Float(k) / 10 * 6.28318
                    vs.append(Splat(pos: p.pos, force: SIMD2<Float>(cos(a), sin(a)) * 3800, color: .zero, radius: 0.0012))
                }
                ds.append(Splat(pos: p.pos, force: .zero, color: SIMD4<Float>(0.6, 0.55, 0.5, 1), radius: 0.002))
            }
            emitters.append(SIMD4<Float>(p.pos.x, p.pos.y, 0.03, 1))
        }
        for i in pointers.indices { pointers[i].burst = false }
        // beat ring emitters (8), weighted by spectrum
        if live {
            for k in 0..<max(0, 8 - emitters.count) {
                let a = Float(k) / 8 * 6.28318 + t * 0.1
                let band = s.spectrum[min(127, k * 16 + 8)]
                emitters.append(SIMD4<Float>(0.5 + cos(a) * 0.3 / aspect, 0.5 + sin(a) * 0.3, 0.02 + 0.03 * band, band > 0.2 ? 1 : 0))
            }
        }

        guard let enc = cb.makeComputeCommandEncoder() else { return }
        let texel = SIMD2<Float>(1 / Float(simW), 1 / Float(simH))
        // velocity: advect
        var P = SIMD4<Float>(dt, 0.25 + 0.6 * (1 - energy) * 0.3, texel.x, texel.y)
        enc.setTexture(vel[0], index: 0); enc.setTexture(vel[0], index: 1); enc.setTexture(vel[1], index: 2)
        enc.setBytes(&P, length: 16, index: 0); dispatch(enc, pAdvect, simW, simH); vel.swapAt(0, 1)
        // splats
        func applySplats(_ list: [Splat], _ target: inout [MTLTexture], mode: Float) {
            guard !list.isEmpty else { return }
            var am = SIMD2<Float>(aspect, mode); var n = UInt32(list.count)
            enc.setTexture(target[0], index: 0); enc.setTexture(target[1], index: 1)
            list.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.setBytes(&n, length: 4, index: 1); enc.setBytes(&am, length: 8, index: 2)
            dispatch(enc, pSplat, target[0].width, target[0].height); target.swapAt(0, 1)
        }
        applySplats(Array(vs.prefix(64)), &vel, mode: 0)
        if maskActive {
            var M = SIMD4<Float>(0, 900, hue, t)
            enc.setTexture(vel[0], index: 0); enc.setTexture(vel[1], index: 1); enc.setTexture(mask, index: 2)
            enc.setBytes(&M, length: 16, index: 0); dispatch(enc, pMask, simW, simH); vel.swapAt(0, 1)
        }
        // vorticity confinement (stronger during build-ups)
        enc.setTexture(vel[0], index: 0); enc.setTexture(curl, index: 1); dispatch(enc, pCurl, simW, simH)
        var VP = SIMD2<Float>(dt, curlStrength * (1 + 1.5 * build) * (0.6 + 0.6 * energy))
        enc.setTexture(vel[0], index: 0); enc.setTexture(curl, index: 1); enc.setTexture(vel[1], index: 2)
        enc.setBytes(&VP, length: 8, index: 0); dispatch(enc, pVort, simW, simH); vel.swapAt(0, 1)
        // projection
        enc.setTexture(vel[0], index: 0); enc.setTexture(div, index: 1); dispatch(enc, pDiv, simW, simH)
        var keep: Float = 0.8
        enc.setTexture(prs[0], index: 0); enc.setTexture(prs[1], index: 1); enc.setBytes(&keep, length: 4, index: 0)
        dispatch(enc, pScale, simW, simH); prs.swapAt(0, 1)
        for _ in 0..<20 {
            enc.setTexture(prs[0], index: 0); enc.setTexture(div, index: 1); enc.setTexture(prs[1], index: 2)
            dispatch(enc, pPress, simW, simH); prs.swapAt(0, 1)
        }
        enc.setTexture(prs[0], index: 0); enc.setTexture(vel[0], index: 1); enc.setTexture(vel[1], index: 2)
        dispatch(enc, pGrad, simW, simH); vel.swapAt(0, 1)
        // dye: splats + body, then advect
        applySplats(Array(ds.prefix(64)), &dye, mode: 1)
        if maskActive {
            var M = SIMD4<Float>(1, 0.06, hue, t)
            enc.setTexture(dye[0], index: 0); enc.setTexture(dye[1], index: 1); enc.setTexture(mask, index: 2)
            enc.setBytes(&M, length: 16, index: 0); dispatch(enc, pMask, dye[0].width, dye[0].height); dye.swapAt(0, 1)
        }
        var PD = SIMD4<Float>(dt, 0.9 + 0.8 * (1 - energy), texel.x, texel.y)
        enc.setTexture(vel[0], index: 0); enc.setTexture(dye[0], index: 1); enc.setTexture(dye[1], index: 2)
        enc.setBytes(&PD, length: 16, index: 0); dispatch(enc, pAdvect, dye[0].width, dye[0].height); dye.swapAt(0, 1)

        // particles
        pu[0] = dt; pu[1] = t; pu[2] = energy; pu[3] = u[9]; pu[4] = hue; pu[5] = 0.35 + 0.9 * energy; pu[6] = u[17]; pu[7] = maskActive ? 1 : 0
        pu[8] = texel.x; pu[9] = texel.y; pu[10] = Float(size.width); pu[11] = Float(size.height)
        for i in 0..<8 {
            let e = i < emitters.count ? emitters[i] : .zero
            pu[12 + i * 4] = e.x; pu[13 + i * 4] = e.y; pu[14 + i * 4] = e.z; pu[15 + i * 4] = e.w
        }
        pu[44] = Float(bitPattern: UInt32(min(8, emitters.count))); pu[45] = Float(bitPattern: UInt32(particleCount))
        pu[48] = Float(min(4.0, 1_000_000.0 / Double(max(1, particleCount))))   // fewer particles -> each brighter
        pu[46] = 1.0; pu[47] = Float(max(1.5, size.height / 720 * 2.0))
        enc.setComputePipelineState(pParticles)
        enc.setBuffer(particleBuf, offset: 0, index: 0)
        pu.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.setTexture(vel[0], index: 0); enc.setTexture(mask, index: 1)
        enc.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()

        // draw dye + particles into HDR
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdr; rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = .store
        if let r = cb.makeRenderCommandEncoder(descriptor: rp) {
            var gain: Float = 1.0
            r.setRenderPipelineState(pDye); r.setFragmentTexture(dye[0], index: 0); r.setFragmentBytes(&gain, length: 4, index: 0)
            r.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            r.setRenderPipelineState(pDraw)
            r.setVertexBuffer(particleBuf, offset: 0, index: 0)
            pu.withUnsafeBytes { r.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            r.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            r.endEncoding()
        }
        // bloom (MPS): half-res copy, two blur radii
        MPSImageBilinearScale(device: device).encode(commandBuffer: cb, sourceTexture: hdr, destinationTexture: half)
        MPSImageGaussianBlur(device: device, sigma: 6).encode(commandBuffer: cb, sourceTexture: half, destinationTexture: bloomA)
        if fullBloom { MPSImageGaussianBlur(device: device, sigma: 22).encode(commandBuffer: cb, sourceTexture: half, destinationTexture: bloomB) }
        if let r = cb.makeRenderCommandEncoder(descriptor: rpd) {
            var F = SIMD4<Float>(0.8 + 0.6 * u[17], strobe, blackout ? 1 : 0, fade)
            r.setRenderPipelineState(pFinal)
            r.setFragmentTexture(hdr, index: 0); r.setFragmentTexture(bloomA, index: 1); r.setFragmentTexture(fullBloom ? bloomB : bloomA, index: 2)
            r.setFragmentBytes(&F, length: 16, index: 0)
            var G = SIMD4<Float>(Float(symmetry), aspect, 0, 0)
            r.setFragmentBytes(&G, length: 16, index: 1)
            r.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            r.endEncoding()
        }
    }
}
