// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Metal
import simd
import XCTest
@testable import RaveLiveApp

/// The Stage skips the crowd rows a pixel can't touch, and the rim-light probe where no one stands. These prove the
/// skip changes nothing on screen: the row bound holds every pixel a person can reach (feet to raised hands at the top
/// of a jump), and frames match the same shader with the skips taken out.
final class StageCrowdCullTests: XCTestCase {
    /// `#define <name> <value>` from the Stage shader source.
    private func shaderConstant(_ name: String) throws -> Float {
        let line = try XCTUnwrap(stageShaderSource.split(separator: "\n").first { $0.hasPrefix("#define \(name) ") },
                                 "the Stage shader has no \(name): the crowd loop doesn't skip rows")
        let value = line.dropFirst("#define \(name) ".count).split(separator: " ").first.map(String.init) ?? ""
        return try XCTUnwrap(Float(value), "\(name) isn't a number: \(line)")
    }

    // Swift copy of the shader's person() SDF (Shaders.swift), in a row's own units.
    private func segDist(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let pa = p - a, ba = b - a
        let h = min(1, max(0, simd_dot(pa, ba) / simd_dot(ba, ba)))
        return simd_length(pa - ba * h)
    }
    private func person(_ pIn: SIMD2<Float>, h: Float, jump: Float, hands: Float, seed: Float) -> Float {
        var p = pIn
        p.y -= jump
        let head = simd_length(p - SIMD2<Float>(0, 0.62 * h)) - 0.085 * h
        let q = p - SIMD2<Float>(0, 0.24 * h)
        let k = min(1, max(0, q.y / (0.5 * h) + 0.5))
        let taper = (0.07 + (0.10 - 0.07) * k) * h
        let bq = simd_max(simd_abs(q) - SIMD2<Float>(taper, 0.26 * h), SIMD2<Float>(0, 0))
        var body = simd_length(bq) - 0.035 * h
        let shoulders = simd_length((p - SIMD2<Float>(0, 0.47 * h)) / SIMD2<Float>(1.0, 0.55)) - 0.13 * h
        let nq = simd_max(simd_abs(p - SIMD2<Float>(0, 0.54 * h)) - SIMD2<Float>(0.03 * h, 0.05 * h), SIMD2<Float>(0, 0))
        let neck = simd_length(nq)
        body = min(body, min(shoulders, neck))
        let wave = sin(seed * 9.0 + jump * 30.0) * 0.08
        let sh = SIMD2<Float>(0.12 * h, 0.45 * h)
        let lo = SIMD2<Float>(0.20 * h, 0.05 * h), up = SIMD2<Float>(0.28 * h + wave * h, 1.05 * h)
        let hand = lo + (up - lo) * hands
        let arms = segDist(SIMD2<Float>(abs(p.x), p.y), sh, hand) - 0.035 * h
        return min(min(head, body), arms)
    }

    /// A pixel only gets crowd colour when a person is closer than 0.003 screen units; rows are at least 0.24 screen
    /// units per row unit, so 0.0125 row units. Every such point must sit inside CROWD_Q_LO ... CROWD_Q_HI.
    func testRowBoundHoldsEveryPixelAPersonCanReach() throws {
        let lo = try shaderConstant("CROWD_Q_LO"), hi = try shaderConstant("CROWD_Q_HI")
        let eps: Float = 0.003 / 0.24
        var minY = Float.infinity, maxY = -Float.infinity
        // height 0.85...1.10, hop 0...0.168 (JUMP 1, |sin| 1, seed 1), hands down...up; seed only moves the hands sideways
        for h: Float in [0.85, 1.10] {
            for jump: Float in [0, 0.168] {
                for hands: Float in [0, 0.5, 1] {
                    for seed: Float in [0.05, 0.4, 0.95] {
                        var y: Float = -0.4
                        while y < 1.9 {
                            var x: Float = -0.5
                            while x < 0.5 {
                                if person(SIMD2<Float>(x, y), h: h, jump: jump, hands: hands, seed: seed) < eps { minY = min(minY, y); maxY = max(maxY, y) }
                                x += 0.005
                            }
                            y += 0.002
                        }
                    }
                }
            }
        }
        XCTAssertLessThan(minY, 0.0, "the sweep should reach the feet")
        XCTAssertGreaterThan(maxY, 1.3, "the sweep should reach raised hands at the top of a jump")
        XCTAssertGreaterThan(minY, lo + 0.01, "a person reaches below CROWD_Q_LO: rows would be cut off at the bottom")
        XCTAssertLessThan(maxY, hi - 0.01, "a person reaches above CROWD_Q_HI: raised hands would be cut off")
    }

    /// The same frame with and without the skips, for an idle stage, a build and a drop (crowd jumping, hands up).
    func testFramesMatchTheShaderWithoutSkips() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { throw XCTSkip("no Metal device on this machine") }
        let marked = stageShaderSource.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains("[crowd-cull]") }
        XCTAssertEqual(marked.count, 2, "expected the row skip and the rim-probe skip, each marked [crowd-cull]")
        let noSkips = stageShaderSource.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("[crowd-cull]") }.joined(separator: "\n")
        func pipeline(_ src: String) throws -> MTLRenderPipelineState {
            let lib = try dev.makeLibrary(source: src, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain"); d.fragmentFunction = lib.makeFunction(name: "fmain")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try dev.makeRenderPipelineState(descriptor: d)
        }
        let culled = try pipeline(stageShaderSource), reference = try pipeline(noSkips)
        let w = 384, h = 216
        func render(_ p: MTLRenderPipelineState, _ u: [Float]) throws -> [UInt8] {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = dev.hasUnifiedMemory ? .shared : .managed
            let tex = try XCTUnwrap(dev.makeTexture(descriptor: td))
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            let e = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rp))
            e.setRenderPipelineState(p); e.setFragmentBytes(u, length: u.count * 4, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
            if tex.storageMode == .managed, let b = cb.makeBlitCommandEncoder() { b.synchronize(resource: tex); b.endEncoding() }
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return px
        }
        // uniform slots as in Shaders.swift / Renderer.draw
        func state(time: Float, fade: Float, energy: Float, jump: Float, hands: Float, density: Float, phase: Float,
                   build: Float, drop: Float, fire: Float, sparks: Float, co2: Float, look: Float) -> [Float] {
            var u = [Float](repeating: 0, count: 48)
            u[0] = Float(w); u[1] = Float(h); u[2] = time; u[3] = energy
            u[4] = 0.7; u[5] = 0.6; u[6] = 0.4; u[7] = 0.5; u[8] = 0.3
            u[9] = 0.6; u[10] = 0.3; u[11] = 0.2; u[12] = 0.5; u[13] = phase
            u[16] = fade; u[17] = drop; u[18] = 1; u[19] = drop > 0 ? 1 : 0.3
            u[20] = jump; u[21] = hands; u[22] = density; u[23] = fire; u[24] = 0.2; u[25] = 81; u[26] = 1
            u[27] = look; u[28] = 3; u[29] = 2; u[30] = drop > 0 ? 0.35 : 1; u[31] = sparks; u[32] = co2; u[33] = 0.3; u[34] = build
            u[35] = 15; u[36] = 0.4; u[37] = 81.3; u[38] = 1
            return u
        }
        let cases: [(String, [Float])] = [
            ("idle", state(time: 4, fade: 0.2, energy: 0.1, jump: 0, hands: 0.1, density: 0.25, phase: 0.1, build: 0, drop: 0, fire: 0, sparks: 0, co2: 0, look: 0)),
            ("build", state(time: 35, fade: 1, energy: 0.6, jump: 0.3, hands: 0.8, density: 0.8, phase: 0.6, build: 0.8, drop: 0, fire: 0, sparks: 0, co2: 0, look: 3)),
            ("drop", state(time: 40.2, fade: 1, energy: 0.9, jump: 1, hands: 1, density: 1, phase: 0.42, build: 0, drop: 0.9, fire: 0.8, sparks: 1, co2: 0.7, look: 2)),
            ("drop, top of the jump", state(time: 40.4, fade: 1, energy: 0.95, jump: 1, hands: 1, density: 1, phase: 0.5, build: 0, drop: 0.8, fire: 0.6, sparks: 1, co2: 0.5, look: 4)),
        ]
        // Metal compiles with fast math, so the two variants may round a stray pixel differently (1/255). Anything more
        // (a skipped row that should have drawn) differs by far more, over whole silhouettes.
        for (name, u) in cases {
            let a = try render(culled, u), b = try render(reference, u)
            var maxDiff = 0, differing = 0, at: [String] = []
            for i in 0..<a.count where a[i] != b[i] {
                differing += 1; maxDiff = max(maxDiff, abs(Int(a[i]) - Int(b[i])))
                if at.count < 6 { at.append("(\(i / 4 % w),\(i / 4 / w))") }
            }
            print("crowd-cull \(name): \(differing) of \(a.count) channel values differ, max \(maxDiff)/255 \(at.joined(separator: " "))")
            XCTAssertLessThanOrEqual(maxDiff, 1, "\(name): a pixel differs by \(maxDiff)/255 at \(at)")
            XCTAssertLessThanOrEqual(differing, a.count / 10_000, "\(name): \(differing) channel values differ")
        }
    }
}
