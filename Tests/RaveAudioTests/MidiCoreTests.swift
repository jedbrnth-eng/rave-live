// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveAudio

final class MidiCoreTests: XCTestCase {
    func testParseUMP() {
        XCTAssertEqual(MidiEvent.parse(umpWord: 0x20B0_0740), .cc(channel: 0, number: 7, value: 0x40))
        XCTAssertEqual(MidiEvent.parse(umpWord: 0x2093_2464), .noteOn(channel: 3, number: 0x24, velocity: 0x64))
        XCTAssertEqual(MidiEvent.parse(umpWord: 0x2090_2400), .noteOff(channel: 0, number: 0x24))   // note-on velocity 0
        XCTAssertEqual(MidiEvent.parse(umpWord: 0x2081_2410), .noteOff(channel: 1, number: 0x24))
        XCTAssertEqual(MidiEvent.parse(umpWord: 0x10F8_0000), .clockTick)
        XCTAssertEqual(MidiEvent.parse(umpWord: 0x10FA_0000), .start)
        XCTAssertNil(MidiEvent.parse(umpWord: 0x20E0_0040))   // pitch bend: not mapped
    }

    func testClockEstimatorWithJitter() {
        let est = MidiClockEstimator()
        let period = 60.0 / (128.0 * 24.0)
        var rng: UInt64 = 42
        for i in 0..<200 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let jitter = (Double(rng >> 33) / Double(1 << 31) - 0.5) * 0.004     // +-2 ms per tick
            est.tick(at: 10 + Double(i) * period + jitter)
        }
        let b = try! XCTUnwrap(est.bpm)
        XCTAssertEqual(b, 128, accuracy: 0.5)
        XCTAssertTrue(est.isPresent(now: 10 + 200 * period))
        XCTAssertFalse(est.isPresent(now: 10 + 200 * period + 1))
    }

    func testClockNeedsOneBeatAndResetsOnGap() {
        let est = MidiClockEstimator()
        for i in 0..<10 { est.tick(at: Double(i) * 0.02) }
        XCTAssertNil(est.bpm)
        for i in 0..<30 { est.tick(at: 5 + Double(i) * 0.02) }   // 4.8 s gap: old ticks dropped
        XCTAssertEqual(try XCTUnwrap(est.bpm), 125, accuracy: 0.01)
    }

    func testMappingLearnAndRoundTrip() throws {
        var m = MidiMappingSet()
        let knob = MidiControlID(kind: .cc, channel: 0, number: 1), pad = MidiControlID(kind: .note, channel: 9, number: 36)
        m.bind(knob, to: "intensity")
        m.bind(pad, to: "presetNext")
        m.bind(knob, to: "brightness")              // re-learning a control moves it
        XCTAssertEqual(m.action(for: knob), "brightness")
        XCTAssertNil(m.control(for: "intensity"))
        XCTAssertEqual(m.mappings.count, 2)
        let back = try MidiMappingSet.decode(m.encoded())
        XCTAssertEqual(back, m)
    }

    func testTriggerEdges() {
        let s = MidiTriggerState()
        XCTAssertEqual(s.trigger(for: .cc(channel: 0, number: 20, value: 30))?.pressed, false)
        XCTAssertEqual(s.trigger(for: .cc(channel: 0, number: 20, value: 100))?.pressed, true)
        XCTAssertEqual(s.trigger(for: .cc(channel: 0, number: 20, value: 120))?.pressed, false)
        XCTAssertEqual(s.trigger(for: .cc(channel: 0, number: 20, value: 0))?.released, true)
        XCTAssertEqual(s.trigger(for: .noteOn(channel: 0, number: 36, velocity: 90))?.pressed, true)
        XCTAssertEqual(s.trigger(for: .noteOff(channel: 0, number: 36))?.released, true)
    }
}
