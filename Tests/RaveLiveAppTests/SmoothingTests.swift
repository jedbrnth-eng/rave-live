// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

final class SmoothingTests: XCTestCase {
    /// One hit at 60 fps: eases in (no one-frame jump to full), peaks near 1, fades over ~release.
    func testPulseEasesInAndOut() {
        var p = Pulse(attack: 0.018, release: 0.16)
        let dt: Float = 1 / 60
        var vals: [Float] = []
        for i in 0..<60 { vals.append(p.step(i == 0, dt: dt)) }
        let peak = vals.max()!, peakAt = vals.firstIndex(of: peak)!
        XCTAssertGreaterThan(peak, 0.85); XCTAssertLessThan(peak, 1.15)
        XCTAssertLessThan(vals[0], 0.8, "first frame must not jump to full")
        XCTAssertLessThanOrEqual(peakAt, 3, "peak within ~50 ms")
        // 10 frames (~170 ms) after the peak it has clearly faded, but not vanished
        XCTAssertLessThan(vals[peakAt + 10], 0.55); XCTAssertGreaterThan(vals[peakAt + 10], 0.1)
        XCTAssertLessThan(vals[59], 0.02)
    }

    /// The same envelope whatever the frame rate (a stalled 100 ms frame doesn't overshoot).
    func testPulseFrameRateIndependent() {
        var a = Pulse(attack: 0.018, release: 0.16), b = a
        var ta: Float = 0, tb: Float = 0
        _ = a.step(true, dt: 1 / 120); _ = b.step(true, dt: 1 / 30)
        for _ in 0..<11 { _ = a.step(false, dt: 1 / 120); ta += 1 / 120 }
        for _ in 0..<2 { _ = b.step(false, dt: 1 / 30); tb += 1 / 30 }
        XCTAssertEqual(a.current, b.current, accuracy: 0.06)
        var c = Pulse(attack: 0.018, release: 0.16)
        XCTAssertLessThan(c.step(true, dt: 0.1), 1.2)
    }

    func testDampedHasNoOvershoot() {
        var d = Damped()
        var maxV: Float = 0
        for _ in 0..<200 { maxV = max(maxV, d.step(1, dt: 1 / 60, omega: 30)) }
        XCTAssertLessThanOrEqual(maxV, 1.0001)
        XCTAssertEqual(d.x, 1, accuracy: 0.001)
        var e = Damped()
        _ = e.step(1, dt: 0.1, omega: 30)      // long frame: still stable
        XCTAssertLessThanOrEqual(e.x, 1.0001)
    }

    /// Band noise of +-0.3 around 0.5 every frame comes out much calmer, but a real step still gets through in ~0.15 s.
    func testSmootherCalmsJitterKeepsSteps() {
        var sm = AudioSmoother()
        var s = AudioSnapshot()
        var outs: [Float] = []
        for i in 0..<120 {
            s.bands = [Float](repeating: i % 2 == 0 ? 0.8 : 0.2, count: 5)
            outs.append(sm.step(s, dt: 1 / 60).bands[0])
        }
        let tail = outs.suffix(60)
        XCTAssertLessThan(tail.max()! - tail.min()!, 0.12)
        s.bands = [Float](repeating: 1, count: 5)
        var v: Float = 0
        for _ in 0..<12 { v = sm.step(s, dt: 1 / 60).bands[0] }
        XCTAssertGreaterThan(v, 0.85)
    }

    /// The beat pulse peaks on the beat (phase 0), starts rising just before it, and is continuous.
    func testBeatPulsePeaksOnBeat() {
        XCTAssertEqual(beatPulse(phase: 0, bpm: 128, lead: 0.035, release: 0.13), 1, accuracy: 1e-5)
        XCTAssertGreaterThan(beatPulse(phase: 0.98, bpm: 128, lead: 0.035, release: 0.13), 0.3)
        XCTAssertLessThan(beatPulse(phase: 0.9, bpm: 128, lead: 0.035, release: 0.13), 0.1)
        var last = beatPulse(phase: 0, bpm: 128, lead: 0.035, release: 0.13)
        var maxStep: Float = 0
        for i in 1...1000 {
            let v = beatPulse(phase: Double(i % 1000) / 1000, bpm: 128, lead: 0.035, release: 0.13)
            maxStep = max(maxStep, abs(v - last)); last = v
        }
        XCTAssertLessThan(maxStep, 0.08, "no jumps at 1/1000 beat resolution")
    }

    /// Probe statistics: a static frame reports nothing, a shifted frame reports motion without residual,
    /// a flash reports a brightness change.
    func testProbeCompare() {
        let w = 64, h = 36
        var a = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { a[y * w + x] = Float((x * 7 + y * 13) % 17) / 17 } }
        let same = SmoothProbe.compare(a, a, w: w, h: h)
        XCTAssertEqual(same.flick, 0); XCTAssertEqual(same.resid, 0); XCTAssertEqual(same.motion, 0)
        var shifted = a
        for y in 0..<h { for x in 1..<w { shifted[y * w + x] = a[y * w + x - 1] } }
        let mv = SmoothProbe.compare(a, shifted, w: w, h: h)
        XCTAssertGreaterThan(mv.flick, 0.1)
        XCTAssertLessThan(mv.resid, 0.03)
        XCTAssertGreaterThan(mv.motion, 0.8)
        let flash = SmoothProbe.compare(a, a.map { min(1, $0 + 0.3) }, w: w, h: h)
        XCTAssertGreaterThan(flash.dmean, 0.2)
        XCTAssertGreaterThan(flash.resid, 0.2)
    }

    /// The analyzer's bar guess flipping by a beat every other beat must not move the counter; a lasting
    /// re-alignment is adopted after 8 beats; a drop is adopted at once.
    func testBeatCounterIgnoresFlipFlops() {
        var c = BeatCounter()
        var out: [Int] = [], jumps = 0
        for b in 0..<32 {
            for f in 0..<30 {
                let ph = Double(f) / 30
                let flip = (b % 2 == 1 && ph > 0.2) ? 3 : 0           // like the demo: +3 for part of every other beat
                let r = c.step(target: b + flip, phase: ph, adoptNow: false)
                if r.jumped { jumps += 1 }
                if f == 15 { out.append(r.beat) }
            }
        }
        XCTAssertEqual(jumps, 0)
        XCTAssertEqual(out, Array(0..<32))
        // a lasting offset of +2 is adopted once, after 8 beats
        var adopted = -1
        for b in 32..<48 {
            for f in 0..<30 {
                let r = c.step(target: b + 2, phase: Double(f) / 30, adoptNow: false)
                if r.jumped && adopted < 0 { adopted = b }
            }
        }
        XCTAssertEqual(adopted, 39)          // the 8th beat that agreed (32...39)
        XCTAssertEqual(c.realigns, 1)
        let d = c.step(target: 100, phase: 0.1, adoptNow: true)
        XCTAssertEqual(d.beat, 100)
    }

    /// projectM's beat sensitivity stays calm on Normal even at a drop during a build; Wild may go higher.
    func testMilkDropSensitivityAndEasing() {
        XCTAssertLessThanOrEqual(MilkDropRenderer.beatSensitivity(intensity: 1, build: 1, drop: 1), 1.3 + 1e-6)
        XCTAssertGreaterThan(MilkDropRenderer.beatSensitivity(intensity: 2, build: 1, drop: 1), 2)
        XCTAssertLessThan(MilkDropRenderer.beatSensitivity(intensity: 0, build: 0, drop: 0), MilkDropRenderer.beatSensitivity(intensity: 1, build: 0, drop: 0))
        XCTAssertEqual(MilkDropRenderer.beatSensitivity(intensity: 1, build: 5, drop: -3), MilkDropRenderer.beatSensitivity(intensity: 1, build: 1, drop: 0))
        XCTAssertLessThan(MilkDropRenderer.temporalBlend(intensity: 1), 1)
        XCTAssertGreaterThan(MilkDropRenderer.temporalBlend(intensity: 2), MilkDropRenderer.temporalBlend(intensity: 1))
    }
}
