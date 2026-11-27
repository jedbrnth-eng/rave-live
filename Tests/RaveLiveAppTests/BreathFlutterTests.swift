// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
#if canImport(RaveLiveApp)
@testable import RaveLiveApp
#endif

/// The breath (the whole frame dimming in the hush before a drop) must not flutter and must not stick.
/// It dims the full frame, so it counts against the 3-a-second flash limit like any other flashing.
final class BreathFlutterTests: XCTestCase {
    /// A level that hovers near the hush threshold and pulses with a roll used to flip the dip on every hit.
    func testBreathNeverFluttersOverThreeTimesASecond() {
        for rate in BreathHarness.pulseRates {
            let s = BreathHarness.scan(rate: rate)
            XCTAssertEqual(s.fades, 132)
            XCTAssertLessThanOrEqual(s.worstPairsPerSecond, 3,
                                     String(format: "pulses at %.1f Hz: %.1f down-and-up pairs in one second (base %.2f, slope %.3f/s, peak x%.1f); %d of %d fades over 3 a second",
                                            rate, s.worstPairsPerSecond, s.worst.base, s.worst.slope, s.worst.peakMul, s.overLimit, s.fades))
        }
    }

    /// A quiet breakdown with a roll and no drop: one dip, capped, then the lights come back and stay.
    func testBreathIsCappedInAQuietBreakdownWithNoDrop() {
        let levels: [Float] = [0.125, 0.05]     // 25 % and 10 % of the groove before it
        for quiet in levels {
            let r = BreathHarness.quietBreakdown(level: quiet)
            XCTAssertGreaterThan(r.maxGap, 0.8, "level \(quiet): the breakdown after a build still dips")
            XCTAssertLessThanOrEqual(r.longestDip, 3, "level \(quiet): one dip lasted \(r.longestDip) s")
            XCTAssertEqual(r.dips, 1, "level \(quiet): no second dip while the level stays low")
            XCTAssertEqual(r.gaps.last ?? 1, 0, accuracy: 0.001, "level \(quiet): the lights are back at the end")
            XCTAssertTrue(r.drops.isEmpty)
        }
    }

    /// Without a drop the lights come back over 0.3 s or more, never as a cut.
    func testBreathEasesOutSlowly() {
        let r = BreathHarness.quietBreakdown(level: 0.125)
        XCTAssertGreaterThan(r.maxGap, 0.8)
        XCTAssertLessThanOrEqual(r.maxFallPerFrame, 1 / (0.3 * 60) + 0.001, "largest one-frame recovery \(r.maxFallPerFrame)")
    }

    /// The designed moment is untouched: build, 2 beats of silence (lights down), drop (lights up at once).
    func testDesignedBuildSilenceDropStillDipsAndDrops() throws {
        let r = BreathHarness.designedDrop()
        XCTAssertEqual(r.drops.count, 1)
        let dropAt: Double = try XCTUnwrap(r.drops.first)
        let silenceEnd: Double = 16 + 10 * BreathHarness.beat
        XCTAssertGreaterThanOrEqual(dropAt, silenceEnd - 0.02)
        XCTAssertLessThanOrEqual(dropAt, silenceEnd + BreathHarness.beat)
        let dropFrame = Int((dropAt * BreathHarness.fps).rounded())
        var deepest: Float = 0
        for i in 0..<dropFrame where r.gaps[i] > deepest { deepest = r.gaps[i] }
        XCTAssertGreaterThan(deepest, 0.8, "the lights are well down in the silence")
        XCTAssertGreaterThan(r.gaps[dropFrame - 1], 0.8, "and still down on the frame before the drop")
        XCTAssertEqual(r.gaps[dropFrame], 0, "the drop clears the dip")
        var after: Float = 0
        for i in dropFrame..<r.gaps.count where r.gaps[i] > after { after = r.gaps[i] }
        XCTAssertLessThan(after, 0.01, "no dip after the drop")
        XCTAssertLessThanOrEqual(r.pairsPerSecond, 1)
    }
}
