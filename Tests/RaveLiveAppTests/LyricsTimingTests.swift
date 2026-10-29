// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

/// Jed (10-29 20:05): "the lyrics are slightly delayed" on Bluetooth buds with YouTube in a Chromium browser.
final class LyricsTimingTests: XCTestCase {
    /// The player's position is already what the listener hears (Chromium's media clock counts the output delay), so the
    /// Bluetooth latency must not be subtracted a second time.
    func testNowPlayingPositionIsNotReducedByOutputLatency() {
        for b in ["app.zen-browser.zen", "com.google.Chrome", "com.apple.Safari", "com.apple.Music", "com.spotify.client", "org.videolan.vlc"] {
            let h = LyricsTiming.heardPosition(sourcePosition: 60, bundleID: b, outputLatency: 0.18, userOffsetMs: 0, videoOffset: 0)
            XCTAssertEqual(h, 60, accuracy: 1e-9, b)
        }
    }

    func testUserTrimAndVideoOffsetStillApply() {
        let h = LyricsTiming.heardPosition(sourcePosition: 60, bundleID: "com.apple.Music", outputLatency: 0.2, userOffsetMs: 100, videoOffset: 12)
        XCTAssertEqual(h, 60 - 0.1 - 12, accuracy: 1e-9)
    }

    /// Lines change a little before they are sung so reading keeps up with the singer.
    func testLineChangesSlightlyEarly() {
        let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 12, text: "b")]
        XCTAssertGreaterThanOrEqual(LyricsTiming.displayLead, 0.1)
        XCTAssertLessThanOrEqual(LyricsTiming.displayLead, 0.2)
        XCTAssertEqual(LyricsTiming.lineIndex(heard: 12 - LyricsTiming.displayLead + 0.001, in: lines), 1)
        XCTAssertEqual(LyricsTiming.lineIndex(heard: 12 - LyricsTiming.displayLead - 0.02, in: lines), 0)
    }

    /// An update with an elapsed time but no timestamp used to freeze the position at that elapsed time while playing,
    /// so the lyrics fell further behind every second until the next update.
    func testElapsedWithoutTimestampKeepsRunning() {
        var s = NowPlayingStream()
        let line = #"{"type":"data","diff":false,"payload":{"title":"T","artist":"A","elapsedTime":10,"playing":true,"playbackRate":1,"duration":200}}"#
        XCTAssertTrue(s.feed(Data(line.utf8), now: 1000))
        XCTAssertEqual(s.info?.position(at: 1002) ?? -1, 12, accuracy: 1e-6)
        let diff = #"{"type":"data","diff":true,"payload":{"elapsedTime":50}}"#
        XCTAssertTrue(s.feed(Data(diff.utf8), now: 1010))
        XCTAssertEqual(s.info?.position(at: 1011) ?? -1, 51, accuracy: 1e-6)
    }

    /// A real timestamp from the adapter is kept as is (it is more precise than our receive time).
    func testAdapterTimestampWins() {
        var s = NowPlayingStream()
        let line = #"{"type":"data","diff":false,"payload":{"title":"T","elapsedTimeMicros":10000000,"timestampEpochMicros":999500000,"playing":true,"playbackRate":1}}"#
        XCTAssertTrue(s.feed(Data(line.utf8), now: 1000))
        XCTAssertEqual(s.info?.position(at: 1000) ?? -1, 10.5, accuracy: 1e-6)
    }

    func testFakeOutputLatencyForTests() {
        XCTAssertNil(OutputLatency.testOverride(env: [:]))
        let i = OutputLatency.testOverride(env: ["RAVE_TEST_OUTPUT_LATENCY_MS": "180"])
        XCTAssertEqual(i?.seconds ?? 0, 0.18, accuracy: 1e-9)
        XCTAssertEqual(i?.transport, "bluetooth")
        XCTAssertNil(OutputLatency.testOverride(env: ["RAVE_TEST_OUTPUT_LATENCY_MS": "nope"]))
    }
}
