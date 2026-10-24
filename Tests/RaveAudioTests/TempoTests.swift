// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveAudio

final class TempoTests: XCTestCase {
    func check(_ p: Synth.Pattern, file: StaticString = #filePath, line: UInt = #line) {
        let r = TempoRun.run(Synth.render(p, seconds: 15), sr: 48000)
        let lock = r.lockTime(truth: p.bpm)
        XCTAssertNotNil(lock, "\(p.name): no lock, final \(r.finalBPM)", file: file, line: line)
        if let l = lock { XCTAssertLessThan(l, 5.0, "\(p.name) lock \(l)s", file: file, line: line) }
        XCTAssertLessThan(abs(r.finalBPM - p.bpm), 0.5, "\(p.name) final \(r.finalBPM)", file: file, line: line)
    }
    func testHouse() { check(Synth.house) }
    func testDnB() { check(Synth.dnb) }
    func testBoomBap() { check(Synth.boomBap) }
    func testRock() { check(Synth.rock) }
    func testMetal() { check(Synth.metal) }
    func testTechno() { check(Synth.techno) }

    func testTransitionRelocksFast() {
        var a = Synth.house; a.bpm = 124
        var b = Synth.house; b.bpm = 132
        let r = TempoRun.run(Synth.render(a, seconds: 15) + Synth.render(b, seconds: 15, seed: 7), sr: 48000)
        let relock = r.lockTime(truth: 132, from: 15)
        XCTAssertNotNil(relock)
        if let l = relock { XCTAssertLessThan(l, 5.0) }
    }

    func testBeatsLandOnKicks() {
        // House: kick on every beat. Predicted beats should sit within 30 ms of the true grid after lock.
        let p = Synth.house
        let r = TempoRun.run(Synth.render(p, seconds: 15), sr: 48000)
        let period = 60 / p.bpm
        let late = r.beats.filter { $0 > 8 }
        XCTAssertFalse(late.isEmpty)
        for b in late {
            var e = b.truncatingRemainder(dividingBy: period)
            if e > period / 2 { e -= period }
            // analysis time is end-of-hop; allow window latency of ~one FFT half-window
            XCTAssertLessThan(abs(e), 0.045, "beat at \(b) off grid by \(e)")
        }
    }

    func testSilenceIsSilent() {
        let a = LiveAnalyzer()
        let frames = a.process([Float](repeating: 0, count: 48000))
        XCTAssertTrue(frames.allSatisfy { $0.silent && $0.bpm == 0 && !$0.kick })
    }

    func testTapTempo() {
        let t = TempoTracker(fps: 93.75)
        for i in 0..<5 { t.tap(at: Double(i) * 0.5) }
        XCTAssertEqual(t.outputBPM, 120, accuracy: 0.01)
        t.nudge = 0.5
        XCTAssertEqual(t.outputBPM, 120.5, accuracy: 0.01)
    }

    /// Regression: live crash (SIGTRAP, Double->Int overflow in acAt) when every tempo score was <= 0,
    /// leaving bestB = 0 and lag = inf. Rhythm-free but non-silent audio (pads, noise, sustained tones).
    func testRhythmlessAudioDoesNotCrash() {
        let sr = 48000.0
        var x = [Float](repeating: 0, count: Int(sr * 12))
        var rng: UInt64 = 3
        for i in 0..<x.count {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n = Float(Int64(bitPattern: rng >> 11) % 2_000_000) / 1_000_000 - 1
            x[i] = 0.3 * Float(sin(2 * Double.pi * 110 * Double(i) / sr)) + 0.002 * n
        }
        // One isolated hit, then near-silence: autocorrelation is zero at every tempo lag.
        for i in 0..<x.count { x[i] = 0.0011 * Float(sin(2 * Double.pi * 3000 * Double(i) / sr)) }
        for i in 0..<2000 { x[Int(sr * 3) + i] += 0.8 * Float(exp(-Double(i) / 200)) * (i % 2 == 0 ? 1 : -1) }
        let r = TempoRun.run(x, sr: sr)
        XCTAssertFalse(r.timeline.isEmpty)
        // A constant tone has no beat; any BPM reported must at least be finite.
        XCTAssertTrue(r.timeline.allSatisfy { $0.bpm.isFinite })
    }
}
