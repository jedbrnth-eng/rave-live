// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Metal
import XCTest
@testable import RaveLiveApp

/// The festival drop: the breath (lights dip in the silence after a build) and the confetti burst on the drop.
final class DropFXTests: XCTestCase {
    /// A small set: groove, a snare-roll build, a hush, then the drop. energyShort / energyLong follow the analyzer's
    /// 0.5 s and 8 s averages. Returns the breath per frame with its time, and the drop time.
    private func playSet(build: Bool, hush: Double = 2 * 60.0 / 128) -> (gap: [(Double, Float)], drop: Double?, director: ShowDirector) {
        let d = ShowDirector()
        let fps = 60.0, beat = 60.0 / 128
        var t = 0.0, eShort: Float = 0.5, eLong: Float = 0.5
        var out: [(Double, Float)] = []
        func step(_ e: Float, kick: Bool, snare: Bool) {
            eShort += (e - eShort) * Float(1 / fps / 0.5); eLong += (e - eLong) * Float(1 / fps / 8)
            let o = d.step(.init(now: t, dt: Float(1 / fps), energy: e, energyShort: eShort, energyLong: eLong, kick: kick, snare: snare,
                                 beatIndex: Int(t / beat), beatLocked: true, playing: e > 0.01))
            out.append((t, o.gap)); t += 1 / fps
        }
        func onGrid(_ div: Double) -> Bool { let x = t / (beat / div); return x - floor(x) < 1 / fps / (beat / div) }
        while t < 16 { step(0.6, kick: onGrid(1), snare: onGrid(0.5)) }                          // groove
        let buildEnd = t + 8 * beat
        while t < buildEnd { step(build ? 0.62 : 0.5, kick: !build && onGrid(1), snare: build && onGrid(t > buildEnd - 2 * beat ? 4 : 2)) }
        let hushEnd = t + hush
        while t < hushEnd { step(0.004, kick: false, snare: false) }                               // the music stops
        let dropAt = t
        while t < dropAt + 3 { step(0.85, kick: onGrid(1), snare: onGrid(0.5)) }
        return (out, d.events.first { $0.1.hasPrefix("drop") }?.0, d)
    }

    func testBreathDipsInTheSilenceAfterABuildAndLiftsOnTheDrop() throws {
        let (gap, drop, _) = playSet(build: true)
        let dropAt = try XCTUnwrap(drop, "the drop after the build must be detected")
        let before = gap.filter { $0.0 < dropAt }.map(\.1).max() ?? 0
        XCTAssertGreaterThan(before, 0.8, "the lights should be well down just before the drop")
        // the lights come up with the drop, eased over a few frames (a one-frame jump is a cut the strobe limit never sees)
        let lift = gap.filter { $0.0 >= dropAt - 1e-9 && $0.0 <= dropAt + DropFXTests.dropLiftLimit }
        XCTAssertEqual(try XCTUnwrap(lift.last).1, 0, "full brightness within \(DropFXTests.dropLiftLimit) s of the drop")
        let onDrop = try XCTUnwrap(gap.first { $0.0 >= dropAt - 1e-9 })
        XCTAssertGreaterThan(onDrop.1, 0.5, "the drop frame starts the lift, it doesn't cut to full brightness")
        XCTAssertLessThan(gap.filter { $0.0 > dropAt + DropFXTests.dropLiftLimit }.map(\.1).max() ?? 1, 0.01, "no second dip after the drop")
        let groove = gap.filter { $0.0 < 16 }.map(\.1).max() ?? 1
        XCTAssertLessThan(groove, 0.01, "no dip during the groove")
    }

    func testNoBreathWhenTheMusicGoesQuietWithoutABuild() {
        let (gap, _, _) = playSet(build: false)
        XCTAssertLessThan(gap.map(\.1).max() ?? 1, 0.05, "a quiet patch without a build isn't a drop: keep the lights")
    }

    /// The lights may lift by at most this much in one 60 fps frame, and must be fully back this long after the drop.
    static let dropMaxLiftPerFrame: Float = 0.2
    static let dropLiftLimit = 0.25

    /// The breath rises over a few frames and lifts over a few frames, never as a one-frame cut (no flashing).
    func testBreathIsEasedNotCut() {
        let (gap, _, _) = playSet(build: true)
        var maxStep: Float = 0, maxLift: Float = 0
        for i in 1..<gap.count {
            if gap[i].1 > gap[i - 1].1 { maxStep = max(maxStep, gap[i].1 - gap[i - 1].1) }
            else { maxLift = max(maxLift, gap[i - 1].1 - gap[i].1) }
        }
        XCTAssertLessThan(maxStep, 0.15, "the dip must ease in")
        XCTAssertLessThanOrEqual(maxLift, DropFXTests.dropMaxLiftPerFrame, "the lights must ease back up on the drop, not jump in one frame")
    }

    /// A zero-width view (a minimised window, the first layout pass) must not divide by zero in the confetti shader.
    func testUniformsNeverHandTheShaderAZeroSize() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this machine") }
        let fx = try XCTUnwrap(DropFX(device: dev, pixelFormat: .bgra8Unorm))
        let u = try XCTUnwrap(fx.uniforms(now: 5, size: .zero, kick: 0, gap: 1, hue: 0, intensity: .normal))
        XCTAssertGreaterThanOrEqual(u[0], 1, "width")
        XCTAssertGreaterThanOrEqual(u[1], 1, "height")
    }

    func testBurstFollowsTheDropAndEnds() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this machine") }
        let fx = try XCTUnwrap(DropFX(device: dev, pixelFormat: .bgra8Unorm))
        let size = CGSize(width: 320, height: 180)
        XCTAssertNil(fx.uniforms(now: 10, size: size, kick: 0, gap: 0, hue: 0, intensity: .normal), "nothing before the first drop")
        fx.update(dropStarted: false, now: 10, fromStage: true)
        XCTAssertNil(fx.burst)
        fx.update(dropStarted: true, now: 12, fromStage: true)
        XCTAssertEqual(fx.burst, DropFX.Burst(time: 12, number: 1, fromStage: true))
        let u = try XCTUnwrap(fx.uniforms(now: 13.5, size: size, kick: 0, gap: 0, hue: 0, intensity: .normal))
        XCTAssertEqual(u[2], 1.5, accuracy: 1e-6)
        XCTAssertEqual(u[4], Float(DropFX.pieces(.normal)))
        XCTAssertEqual(u[8], -0.10, accuracy: 1e-6, "on the Stage the cannons stand on the deck")
        XCTAssertNil(fx.uniforms(now: 12 + DropFX.airTime + 0.1, size: size, kick: 0, gap: 0, hue: 0, intensity: .normal), "the burst is over")
        fx.update(dropStarted: true, now: 50, fromStage: false)
        XCTAssertEqual(fx.burst?.number, 2)
        XCTAssertEqual(try XCTUnwrap(fx.uniforms(now: 51, size: size, kick: 0, gap: 0, hue: 0, intensity: .normal))[8], -1.08, accuracy: 1e-6)
        fx.enabled = false
        XCTAssertNil(fx.uniforms(now: 51, size: size, kick: 0, gap: 1, hue: 0, intensity: .normal), "Settings off: nothing at all")
        XCTAssertLessThan(DropFX.pieces(.chill), DropFX.pieces(.normal)); XCTAssertLessThan(DropFX.pieces(.normal), DropFX.pieces(.wild))
    }

    // MARK: GPU

    private func render(_ fx: DropFX, _ u: [Float], fill: Float, dev: MTLDevice) throws -> [UInt8] {
        let w = Int(u[0]), h = Int(u[1])
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = dev.hasUnifiedMemory ? .shared : .managed
        let tex = try XCTUnwrap(dev.makeTexture(descriptor: td))
        let cb = try XCTUnwrap(dev.makeCommandQueue()?.makeCommandBuffer())
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = tex; clear.colorAttachments[0].loadAction = .clear; clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = MTLClearColorMake(Double(fill), Double(fill), Double(fill), 1)
        cb.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        fx.encode(cb: cb, target: tex, uniforms: u)
        if tex.storageMode == .managed, let b = cb.makeBlitCommandEncoder() { b.synchronize(resource: tex); b.endEncoding() }
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px
    }

    /// 1.2 s after the drop the sky is full of metallic paper; the same moment renders the same bytes.
    func testConfettiFillsTheFrameOnTheDropInGoldAndSilver() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this machine") }
        let fx = try XCTUnwrap(DropFX(device: dev, pixelFormat: .bgra8Unorm))
        fx.update(dropStarted: true, now: 100, fromStage: false)
        let u = try XCTUnwrap(fx.uniforms(now: 101.2, size: CGSize(width: 480, height: 270), kick: 0.5, gap: 0, hue: 0.6, intensity: .normal))
        let a = try render(fx, u, fill: 0, dev: dev), b = try render(fx, u, fill: 0, dev: dev)
        XCTAssertEqual(a, b, "a burst is a pure function of the time since the drop")
        var lit = 0, warmOrNeutral = 0, rows = Set<Int>()
        for i in stride(from: 0, to: a.count, by: 4) {
            let bl = Int(a[i]), g = Int(a[i + 1]), r = Int(a[i + 2])
            guard max(r, g, bl) > 40 else { continue }
            lit += 1; rows.insert(i / 4 / 480 / 27)
            let hi = max(r, g, bl), lo = min(r, g, bl)
            if r >= bl - 12 || hi - lo <= hi / 4 { warmOrNeutral += 1 }   // gold / champagne (warm) or silver (unsaturated), not a rainbow
        }
        let frame = a.count / 4
        XCTAssertGreaterThan(Double(lit) / Double(frame), 0.01, "the burst should be visible across the frame")
        XCTAssertGreaterThan(Double(warmOrNeutral) / Double(max(lit, 1)), 0.8, "mostly metallic gold and silver")
        XCTAssertGreaterThanOrEqual(rows.count, 6, "pieces spread over the height of the frame, not one band")
    }

    /// The breath darkens a lit frame, and only as deep as the intensity allows.
    func testBreathDarkensTheFrame() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this machine") }
        let fx = try XCTUnwrap(DropFX(device: dev, pixelFormat: .bgra8Unorm))
        let u = try XCTUnwrap(fx.uniforms(now: 5, size: CGSize(width: 64, height: 36), kick: 0, gap: 1, hue: 0, intensity: .normal))
        let px = try render(fx, u, fill: 1, dev: dev)
        let level = Float(px[1]) / 255
        XCTAssertEqual(level, 1 - DropFX.breathDepth(.normal), accuracy: 0.02)
    }
}
