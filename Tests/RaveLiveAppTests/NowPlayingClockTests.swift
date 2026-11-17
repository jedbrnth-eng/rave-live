// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

/// Players that stop sending a position. Seen live with YouTube in Zen (Firefox engine), 2026-11-17: after an autoplay
/// to the next video the elapsed time and length went null a second after the song started, and stayed missing for
/// the whole song; later updates carried only a new timestamp. The old stream read a missing elapsed as 0 at the newest
/// timestamp, so every timestamp-only update restarted the song clock and the lyrics fell a minute behind.
final class NowPlayingClockTests: XCTestCase {
    private let base = 1_794_929_000.0
    private func feed(_ s: inout NowPlayingStream, _ json: String, at t: Double) { XCTAssertTrue(s.feed(Data(json.utf8), now: base + t)) }
    private func us(_ t: Double) -> String { String(format: "%.0f", (base + t) * 1e6) }

    /// The recorded stream (made-up titles, real timing and key pattern). The song really started at t=822.57: the
    /// pause at t=1162.70 reports elapsed 340.126 s.
    func testRealZenYouTubeStreamKeepsTheSongClock() {
        var s = NowPlayingStream()
        let song = #""title":"Song A","artist":"Band","album":"","bundleIdentifier":"app.zen-browser.zen""#
        feed(&s, #"{"type":"data","diff":false,"payload":{\#(song),"playing":true,"playbackRate":1,"timestampEpochMicros":\#(us(822.821927))}}"#, at: 822.830)
        feed(&s, #"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":812502,"durationMicros":347221000,"timestampEpochMicros":\#(us(823.381828))}}"#, at: 823.384)
        let key = s.info?.trackKey
        feed(&s, #"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":null,"durationMicros":null,"timestampEpochMicros":\#(us(824.536846))}}"#, at: 824.540)
        XCTAssertEqual(s.info?.duration ?? -1, 347.221, accuracy: 1e-3, "a length the player sent once is kept for the same track")
        XCTAssertEqual(s.info?.trackKey, key, "a dropped length must not look like a new track")
        // a half-updated title from the page for two seconds, then the song again
        feed(&s, #"{"type":"data","diff":false,"payload":{"title":"Song B (Lyric Video)","artist":"Band","album":"","bundleIdentifier":"app.zen-browser.zen","playing":true,"playbackRate":1,"timestampEpochMicros":\#(us(825.071785))}}"#, at: 825.076)
        feed(&s, #"{"type":"data","diff":true,"payload":{"timestampEpochMicros":\#(us(825.648859))}}"#, at: 825.662)
        feed(&s, #"{"type":"data","diff":false,"payload":{\#(song),"playing":true,"playbackRate":1,"timestampEpochMicros":\#(us(827.216053))}}"#, at: 827.222)
        XCTAssertEqual(s.info?.trackKey, key)
        feed(&s, #"{"type":"data","diff":true,"payload":{"timestampEpochMicros":\#(us(887.311864))}}"#, at: 887.322)
        // just before the pause: the clock must still be the song's (340.12 s), not "seconds since the last update"
        XCTAssertEqual(s.info?.position(at: base + 1162.69) ?? -1, 340.12, accuracy: 0.1)
        XCTAssertEqual(s.info?.positionEstimated, false, "anchored on a position the player really sent")
        feed(&s, #"{"type":"data","diff":true,"payload":{"playing":false}}"#, at: 1162.697)
        feed(&s, #"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":340126062,"timestampEpochMicros":\#(us(1162.699747)),"playbackRate":0,"durationMicros":347203875}}"#, at: 1162.702)
        XCTAssertEqual(s.info?.position(at: base + 1170) ?? -1, 340.126, accuracy: 1e-3)
        feed(&s, #"{"type":"data","diff":true,"payload":{"playing":true}}"#, at: 1164.254)
        feed(&s, #"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":340126309,"timestampEpochMicros":\#(us(1164.247318)),"playbackRate":1}}"#, at: 1164.256)
        XCTAssertEqual(s.info?.position(at: base + 1166.247318) ?? -1, 342.126, accuracy: 1e-3)
    }

    /// A track that never gets a position: count from when it appeared, and say the timing is a guess.
    func testTrackWithoutAnyPositionCountsFromWhenItAppeared() {
        var s = NowPlayingStream()
        feed(&s, #"{"type":"data","diff":false,"payload":{"title":"T","artist":"A","bundleIdentifier":"b","playing":true,"playbackRate":1,"timestampEpochMicros":\#(us(100))}}"#, at: 100)
        XCTAssertEqual(s.info?.position(at: base + 110) ?? -1, 10, accuracy: 1e-6)
        XCTAssertEqual(s.info?.positionEstimated, true)
        feed(&s, #"{"type":"data","diff":true,"payload":{"timestampEpochMicros":\#(us(150))}}"#, at: 150)
        XCTAssertEqual(s.info?.position(at: base + 160) ?? -1, 60, accuracy: 1e-6, "a timestamp with no elapsed time is no news")
        // pause and resume without a position: freeze, then continue from the frozen point
        feed(&s, #"{"type":"data","diff":true,"payload":{"playing":false}}"#, at: 170)
        XCTAssertEqual(s.info?.position(at: base + 200) ?? -1, 70, accuracy: 1e-6)
        feed(&s, #"{"type":"data","diff":true,"payload":{"playing":true}}"#, at: 200)
        XCTAssertEqual(s.info?.position(at: base + 205) ?? -1, 75, accuracy: 1e-6)
        // a real position replaces the guess
        feed(&s, #"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":80000000,"timestampEpochMicros":\#(us(206))}}"#, at: 206)
        XCTAssertEqual(s.info?.position(at: base + 207) ?? -1, 81, accuracy: 1e-6)
        XCTAssertEqual(s.info?.positionEstimated, false)
    }

    /// Coming back to a title after a short glitch keeps its clock; playing it again later starts it from zero.
    func testOldClockIsOnlyReusedRightAfterAGlitch() {
        var s = NowPlayingStream()
        let a = #"{"type":"data","diff":false,"payload":{"title":"A","artist":"X","bundleIdentifier":"b","playing":true,"playbackRate":1}}"#
        let b = #"{"type":"data","diff":false,"payload":{"title":"B","artist":"X","bundleIdentifier":"b","playing":true,"playbackRate":1}}"#
        feed(&s, a, at: 0)
        feed(&s, b, at: 10)
        XCTAssertEqual(s.info?.position(at: base + 11) ?? -1, 1, accuracy: 1e-6)
        feed(&s, a, at: 100)
        XCTAssertEqual(s.info?.position(at: base + 101) ?? -1, 1, accuracy: 1e-6, "B played for 90 s: A again is a new play, not a glitch")
        feed(&s, b, at: 104)
        feed(&s, a, at: 106)
        XCTAssertEqual(s.info?.position(at: base + 107) ?? -1, 7, accuracy: 1e-6, "B for 2 s: the same play of A, keep its clock")
    }

    /// Players that send positions normally are untouched: a timestamp-only diff still means "elapsed at this time".
    func testPlayersWithPositionsBehaveAsBefore() {
        var s = NowPlayingStream()
        feed(&s, #"{"type":"data","diff":false,"payload":{"title":"T","bundleIdentifier":"b","playing":false,"playbackRate":0,"elapsedTimeMicros":40000000,"timestampEpochMicros":\#(us(0))}}"#, at: 0)
        XCTAssertEqual(s.info?.positionEstimated, false)
        feed(&s, #"{"type":"data","diff":true,"payload":{"timestampEpochMicros":\#(us(5))}}"#, at: 5)
        XCTAssertEqual(s.info?.position(at: base + 9) ?? -1, 40, accuracy: 1e-6)
    }
}
