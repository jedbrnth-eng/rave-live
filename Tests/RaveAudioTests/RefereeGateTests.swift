import XCTest
@testable import RaveAudio

final class RefereeGateTests: XCTestCase {
    func testRegularGrooveHasSmallResidual() {
        // 128 BPM with +-10 ms quantisation-like jitter (Beat This! frames are 20 ms)
        var beats: [Double] = []
        for i in 0..<20 {
            let jitter: Double = (i % 3 == 0) ? 0.010 : -0.005
            beats.append(1.0 + Double(i) * 0.46875 + jitter)
        }
        let r = BeatReferee.gridResidual(beats, period: 0.46875)
        XCTAssertLessThan(r, 0.05)
    }

    func testScatteredBeatsAreRejectedByGate() {
        // intervals like the Stereo Love intro reports: wildly varying
        var t = 0.0; var beats: [Double] = []
        let gaps: [Double] = [0.31, 0.62, 0.35, 0.80, 0.41, 0.29, 0.77, 0.38, 0.66, 0.33]
        for gap in gaps { t += gap; beats.append(t) }
        var ibis: [Double] = []
        for i in 1..<beats.count { ibis.append(beats[i] - beats[i - 1]) }
        let ibi = ibis.sorted()[ibis.count / 2]
        let r = BeatReferee.gridResidual(beats, period: ibi)
        XCTAssertGreaterThan(r, BeatReferee.gate)
    }

    func testTooFewBeatsOrBadPeriodIsIrregular() {
        XCTAssertEqual(BeatReferee.gridResidual([1.0, 1.5], period: 0.5), .infinity)
        XCTAssertEqual(BeatReferee.gridResidual([1, 1.5, 2, 2.5], period: 0), .infinity)
        XCTAssertEqual(BeatReferee.gridResidual([1, 1.5, 2, 2.5], period: .nan), .infinity)
        XCTAssertEqual(BeatReferee.gridResidual([], period: 0.5), .infinity)
    }

    func testHalfBeatShiftedGridStillRegular() {
        // a constant phase offset is not irregularity: the gate must not reject phase-shifted but steady reports
        var beats: [Double] = []
        for i in 0..<16 { beats.append(0.23 + Double(i) * 0.5) }
        XCTAssertLessThan(BeatReferee.gridResidual(beats, period: 0.5), 0.001)
    }

    func testOffbeatHatsDoNotPullCausalPhase() {
        // Techno: kick on every beat, loud hats on the off-beat. Causal (no referee) beats must sit near the kicks.
        let p = Synth.techno
        let r = TempoRun.run(Synth.render(p, seconds: 20), sr: 48000)
        let period = 60 / p.bpm
        let late = r.beats.filter { $0 > 8 }
        XCTAssertFalse(late.isEmpty)
        for b in late {
            var e = b.truncatingRemainder(dividingBy: period)
            if e > period / 2 { e -= period }
            XCTAssertLessThan(abs(e), 0.045, "beat at \(b) off the kick grid by \(e)")
        }
    }
}
