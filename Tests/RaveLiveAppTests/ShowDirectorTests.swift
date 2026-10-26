// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

final class ShowDirectorTests: XCTestCase {
    /// Groove, a snare-roll build, one beat of silence, then the drop kick: the drop must be detected
    /// (the build score used to decay below the threshold during the silence).
    func testDropAfterBuildAndSilentGap() {
        let d = ShowDirector()
        let fps = 60.0, beat = 60.0 / 128
        var t = 0.0, frame = 0
        var energyLong: Float = 0.5
        func step(_ e: Float, kick: Bool, snare: Bool) {
            energyLong += (e - energyLong) * Float(1 / fps / 8)
            _ = d.step(.init(now: t, dt: Float(1 / fps), energy: e, energyShort: e, energyLong: energyLong, kick: kick, snare: snare,
                             beatIndex: Int(t / beat), beatLocked: true, playing: e > 0.01))
            t += 1 / fps; frame += 1
        }
        func onGrid(_ div: Double) -> Bool { let x = t / (beat / div); return x - floor(x) < 1 / fps / (beat / div) }
        while t < 16 { step(0.6, kick: onGrid(1), snare: onGrid(0.5)) }                  // groove
        let buildEnd = t + 8 * beat
        while t < buildEnd { step(0.55, kick: false, snare: onGrid(t > buildEnd - 2 * beat ? 4 : 2)) }   // snare roll, no kick
        let gapEnd = t + 2 * beat + 2.2                                                      // a long hush: the snare window (2 s) empties
        while t < gapEnd { step(0.4, kick: false, snare: false) }                           // pad keeps the level (no breakdown rule)
        let dropAt = t
        while t < dropAt + 2 { step(0.8, kick: onGrid(1), snare: onGrid(0.5)) }
        let drops = d.events.filter { $0.1.hasPrefix("drop") }
        XCTAssertEqual(drops.count, 1, "events: \(d.events.map { $0.1 })")
        if let first = drops.first {   // on the first kick after the gap (the kick grid is absolute: within one beat)
            XCTAssertGreaterThanOrEqual(first.0, dropAt); XCTAssertLessThanOrEqual(first.0, dropAt + beat + 0.02)
        }
    }
}
