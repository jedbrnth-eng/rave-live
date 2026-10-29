// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

final class LyricStylesTests: XCTestCase {
    // MARK: registry

    func testRegistry() {
        XCTAssertEqual(LyricStyle.default, .clean, "a calm default")
        XCTAssertEqual(LyricStyle.allCases.count, 6)
        XCTAssertEqual(Set(LyricStyle.allCases.map(\.title)).count, 6, "unique titles")
        for s in LyricStyle.allCases { XCTAssertEqual(LyricStyle.from(key: s.rawValue), s); XCTAssertFalse(s.blurb.isEmpty) }
        XCTAssertEqual(LyricStyle.from(key: nil), .clean)
        XCTAssertEqual(LyricStyle.from(key: "chrome-from-the-future"), .clean, "unknown saved value falls back")
        XCTAssertEqual(LyricPosition.from(key: "center"), .center)
        XCTAssertEqual(LyricPosition.from(key: "??"), .lower)
    }

    // MARK: prefs

    private func fresh() -> UserDefaults {
        let name = "ravelive.lyricstyle.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testPrefsPersistStyleAndPosition() {
        let d = fresh()
        let p = Prefs(defaults: d, frozen: false)
        XCTAssertEqual(p.lyricsStyle, .clean)
        XCTAssertEqual(p.lyricsPosition, .lower)
        p.lyricsStyle = .wave; p.lyricsPosition = .center
        let q = Prefs(defaults: d, frozen: false)
        XCTAssertEqual(q.lyricsStyle, .wave)
        XCTAssertEqual(q.lyricsPosition, .center)
        q.reset()
        XCTAssertEqual(q.lyricsStyle, .clean)
        XCTAssertEqual(q.lyricsPosition, .lower)
    }

    func testFrozenPrefsNeverSaveStyle() {
        let d = fresh()
        let p = Prefs(defaults: d, frozen: true)
        p.lyricsStyle = .pop
        XCTAssertNil(d.object(forKey: "lyricsStyle"))
        d.set("neon", forKey: "lyricsStyle")
        XCTAssertEqual(p.lyricsStyle, .clean, "test runs read the defaults")
    }

    // MARK: word timing

    func testSyllables() {
        XCTAssertEqual(WordTiming.syllables("night"), 1)
        XCTAssertEqual(WordTiming.syllables("city"), 2)
        XCTAssertEqual(WordTiming.syllables("breaks"), 1)
        XCTAssertEqual(WordTiming.syllables("electric"), 3)
        XCTAssertEqual(WordTiming.syllables("make"), 1)
        XCTAssertEqual(WordTiming.syllables("—"), 1)
    }

    func testEstimateSpreadsWordsInOrderInsideTheGap() {
        let w = WordTiming.estimate(text: "we run the night until the city breaks", start: 10, nextStart: 14)
        XCTAssertEqual(w.map(\.text), ["we", "run", "the", "night", "until", "the", "city", "breaks"])
        XCTAssertEqual(w.first!.start, 10, accuracy: 1e-9)
        for i in 1..<w.count { XCTAssertEqual(w[i].start, w[i - 1].end, accuracy: 1e-9); XCTAssertGreaterThan(w[i].start, w[i - 1].start) }
        XCTAssertLessThanOrEqual(w.last!.end, 14 * 0.9 + 10 * 0.1 + 1e-9, "finishes before the next line")
        XCTAssertGreaterThan(w[6].end - w[6].start, w[5].end - w[5].start, "two syllables take longer than one")
    }

    func testEstimateLongGapDoesNotStretchTheLine() {
        let w = WordTiming.estimate(text: "hold me", start: 30, nextStart: 42)
        XCTAssertLessThan(w.last!.end - 30, 1.5, "a two-word line before a long break is still sung quickly")
    }

    func testEstimateHandlesEmptyAndLastLine() {
        XCTAssertTrue(WordTiming.estimate(text: "   ", start: 1, nextStart: 2).isEmpty)
        let w = WordTiming.estimate(text: "last line here", start: 100, nextStart: nil)
        XCTAssertEqual(w.count, 3)
        XCTAssertLessThan(w.last!.end, 104.01)
    }

    func testBeatGridNearest() {
        let g = BeatGrid(bpm: 120, refTime: 10, refPhase: 0.25)          // beat at 9.875, 10.375, ...
        XCTAssertEqual(g.nearest(10.4, division: 1), 10.375, accuracy: 1e-9)
        XCTAssertEqual(g.nearest(10.1, division: 2), 10.125, accuracy: 1e-9)   // 8th notes every 0.25 s from 9.875
        XCTAssertEqual(g.nearest(9.0, division: 1), 8.875, accuracy: 1e-9)
    }

    func testQuantizeSnapsNearbyWordsToEighthsKeepingOrder() {
        let g = BeatGrid(bpm: 120, refTime: 0, refPhase: 0)                 // 8ths every 0.25 s
        let w = [TimedWord(text: "a", start: 10.03, end: 10.27), TimedWord(text: "b", start: 10.27, end: 10.55),
                 TimedWord(text: "c", start: 10.55, end: 10.62), TimedWord(text: "d", start: 10.62, end: 11.0)]
        let q = WordTiming.quantize(w, grid: g)
        XCTAssertEqual(q[0].start, 10.03, accuracy: 1e-9, "first word keeps the measured line time")
        XCTAssertEqual(q[1].start, 10.25, accuracy: 1e-9)
        XCTAssertEqual(q[2].start, 10.5, accuracy: 1e-9)
        XCTAssertEqual(q[3].start, 10.62, accuracy: 1e-9, "0.12 s from the 8th at 10.75 is > 35 % of 0.25 s: unchanged")
        for i in 1..<q.count { XCTAssertGreaterThanOrEqual(q[i].start - q[i - 1].start, 0.07 - 1e-9); XCTAssertEqual(q[i - 1].end, q[i].start, accuracy: 1e-9) }
    }

    func testQuantizeWithoutLockChangesNothing() {
        let w = WordTiming.estimate(text: "one two three", start: 5, nextStart: 7)
        XCTAssertEqual(WordTiming.quantize(w, grid: nil), w)
        XCTAssertEqual(WordTiming.quantize(w, grid: BeatGrid(bpm: 0, refTime: 0, refPhase: 0)), w)
    }

    func testEnhancedLRCWordTagsAreUsed() {
        let lines = LRC.parse("[00:10.00]<00:10.00>made <00:10.40>up <00:11.20>words\n[00:13.00]plain line")
        XCTAssertEqual(lines[0].text, "made up words")
        XCTAssertEqual(lines[0].words?.map(\.text), ["made", "up", "words"])
        XCTAssertEqual(lines[0].words?.map(\.start) ?? [], [10, 10.4, 11.2])
        XCTAssertEqual(lines[0].words?[1].end ?? 0, 11.2, accuracy: 1e-9)
        XCTAssertNil(lines[1].words)
        let t = WordTiming.timed(lines[0], nextStart: 13, grid: BeatGrid(bpm: 128, refTime: 0, refPhase: 0))
        XCTAssertEqual(t.map(\.start), [10, 10.4, 11.2], "real word timing is never re-snapped")
    }

    func testChunksForPop() {
        let w = WordTiming.estimate(text: "light it up, we never stop tonight", start: 0, nextStart: 4)
        let c = WordTiming.chunks(w, size: 3)
        XCTAssertEqual(c.map { w[$0].map(\.text).joined(separator: " ") }, ["light it up,", "we never stop", "tonight"])
    }

    // MARK: beat-reactive math

    func testBeatPulse() {
        XCTAssertEqual(LyricFX.beatPulse(phase: 0, locked: true), 1, accuracy: 1e-9)
        XCTAssertEqual(LyricFX.beatPulse(phase: 0.999, locked: true), 1, accuracy: 0.01)
        XCTAssertEqual(LyricFX.beatPulse(phase: 0.5, locked: true), 0)
        XCTAssertEqual(LyricFX.beatPulse(phase: 0, locked: false), 0, "no fake pulse without a tempo lock")
        XCTAssertEqual(LyricFX.beatPulse(phase: .nan, locked: true), 0)
        XCTAssertGreaterThan(LyricFX.beatPulse(phase: 0.1, locked: true), LyricFX.beatPulse(phase: 0.2, locked: true))
    }

    func testSpringOvershootsThenSettles() {
        XCTAssertEqual(LyricFX.spring(0), 0)
        let peak = stride(from: 0.0, to: 1.0, by: 0.005).map { LyricFX.spring($0) }.max()!
        XCTAssertGreaterThan(peak, 1.05); XCTAssertLessThan(peak, 1.25)
        XCTAssertEqual(LyricFX.spring(2), 1, accuracy: 0.01)
    }

    func testPunchIsBoundedAndGentlerWithStrobeOff() {
        XCTAssertEqual(LyricFX.punch(kick: 0, bass: 1, strobe: true), 0)
        XCTAssertLessThanOrEqual(LyricFX.punch(kick: 5, bass: 5, strobe: true), 0.09)
        XCTAssertEqual(LyricFX.punch(kick: 1, bass: 1, strobe: false), LyricFX.punch(kick: 1, bass: 1, strobe: true) / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(LyricFX.punch(kick: 1, bass: 1, strobe: true), LyricFX.punch(kick: 1, bass: 0, strobe: true), "bass adds weight")
    }

    func testGlowFollowsEnergy() {
        XCTAssertLessThan(LyricFX.glow(energy: 0.1, drop: 0), LyricFX.glow(energy: 0.9, drop: 0))
        XCTAssertLessThanOrEqual(LyricFX.glow(energy: 1, drop: 1), 1)
    }

    /// Photosensitivity: with strobe effects off, a target that flips every frame (worst case) can't make the text
    /// brightness swing faster than ~1.25 full cycles per second.
    func testSlewLimitsFlashingWhenStrobeIsOff() {
        var v = 0.0, swings = 0, lastDir = 0
        var maxStep = 0.0
        for f in 0..<120 {                                         // 2 s at 60 fps, target square wave at 30 Hz
            let target = f % 2 == 0 ? 1.0 : 0.0
            let n = LyricFX.slew(v, toward: target, dt: 1.0 / 60, strobe: false)
            maxStep = max(maxStep, abs(n - v))
            v = n
        }
        XCTAssertLessThanOrEqual(maxStep, 2.5 / 60 + 1e-9)
        // a slow square wave at 4 Hz: the output never reaches full swing
        v = 0
        var lo = 1.0, hi = 0.0
        for f in 0..<240 {
            let target = (f / 7) % 2 == 0 ? 1.0 : 0.0
            v = LyricFX.slew(v, toward: target, dt: 1.0 / 60, strobe: false)
            if f > 60 { lo = min(lo, v); hi = max(hi, v) }
            let dir = target > 0.5 ? 1 : -1; if dir != lastDir { swings += 1; lastDir = dir }
        }
        XCTAssertLessThan(hi - lo, 0.35, "a 4 Hz flash becomes a small shimmer")
        XCTAssertGreaterThan(LyricFX.maxRate(strobe: true), LyricFX.maxRate(strobe: false))
    }

    // MARK: auto

    func testAutoStyleFollowsEnergyOnlyAtLineChangesWithHold() {
        var a = AutoStyle()
        XCTAssertEqual(a.update(energy: 0.2, drop: 0, build: 0, now: 0, atLineChange: true), .clean)
        XCTAssertEqual(a.update(energy: 0.9, drop: 0, build: 0, now: 1, atLineChange: false), .clean, "never mid-line")
        XCTAssertEqual(a.update(energy: 0.9, drop: 0, build: 0, now: 2, atLineChange: true), .neon)
        XCTAssertEqual(a.update(energy: 0.5, drop: 0, build: 0, now: 4, atLineChange: true), .neon, "holds 8 s")
        XCTAssertEqual(a.update(energy: 0.5, drop: 0, build: 0, now: 10.5, atLineChange: true), .wave)
        XCTAssertEqual(a.update(energy: 0.5, drop: 0.9, build: 0, now: 11, atLineChange: false), .pop, "a drop cuts in at once, mid-line too")
        XCTAssertEqual(a.update(energy: 0.2, drop: 0.1, build: 0, now: 20, atLineChange: true), .pop, "rides the drop 16 s")
        XCTAssertEqual(a.update(energy: 0.2, drop: 0.1, build: 0, now: 27.5, atLineChange: true), .clean)
        XCTAssertEqual(AutoStyle.target(energy: 0.1, drop: 0, build: 0), .clean)
    }

    // MARK: layout

    func testLayoutWrapsIntoTwoBalancedCentredRows() {
        let (r, size) = LyricLayout.layout(widths: [100, 100, 100, 100, 100], space: 20, maxWidth: 400, rowHeight: 50)
        let rows = Dictionary(grouping: r.indices, by: { r[$0].minY })
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(size.height, 100)
        XCTAssertTrue(r.allSatisfy { $0.minX >= -1e-9 && $0.maxX <= size.width + 1e-9 })
        let counts = rows.values.map(\.count).sorted()
        XCTAssertEqual(counts, [2, 3], "balanced, no lonely last word")
        XCTAssertGreaterThan(r[0].minY, r[4].minY, "first words on the top row")
        let one = LyricLayout.layout(widths: [50, 60], space: 10, maxWidth: 400, rowHeight: 40)
        XCTAssertEqual(one.size, CGSize(width: 120, height: 40))
        XCTAssertTrue(LyricLayout.layout(widths: [], space: 10, maxWidth: 10, rowHeight: 10).rects.isEmpty)
    }
}
