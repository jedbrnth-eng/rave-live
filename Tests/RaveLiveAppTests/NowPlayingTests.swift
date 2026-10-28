// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

final class NowPlayingTests: XCTestCase {
    private func line(_ s: String) -> Data { Data(s.utf8) }

    static let full = #"{"type":"data","diff":false,"payload":{"title":"Made Up Song","artist":"Nobody","album":"Nowhere","bundleIdentifier":"com.example.player","playing":true,"playbackRate":1,"durationMicros":200000000,"elapsedTimeMicros":40000000,"timestampEpochMicros":1700000000000000,"artworkMimeType":"image/png","artworkData":"iVBORw0KGgo="}}"#

    func testFullPayload() {
        var s = NowPlayingStream()
        XCTAssertTrue(s.feed(line(Self.full)))
        let i = s.info
        XCTAssertEqual(i?.title, "Made Up Song"); XCTAssertEqual(i?.artist, "Nobody"); XCTAssertEqual(i?.album, "Nowhere")
        XCTAssertEqual(i?.bundleID, "com.example.player")
        XCTAssertEqual(i?.duration, 200); XCTAssertEqual(i?.elapsed, 40); XCTAssertEqual(i?.timestamp, 1_700_000_000)
        XCTAssertEqual(i?.playing, true)
        XCTAssertEqual(i?.artwork, Data(base64Encoded: "iVBORw0KGgo="))
    }

    func testDiffMergesAndNullRemoves() {
        var s = NowPlayingStream()
        _ = s.feed(line(Self.full))
        XCTAssertTrue(s.feed(line(#"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0,"elapsedTimeMicros":55500000,"timestampEpochMicros":1700000015500000}}"#)))
        XCTAssertEqual(s.info?.playing, false)
        XCTAssertEqual(s.info?.elapsed, 55.5)
        XCTAssertEqual(s.info?.title, "Made Up Song")           // kept from the full payload
        _ = s.feed(line(#"{"type":"data","diff":true,"payload":{"album":null,"artworkData":null}}"#))
        XCTAssertEqual(s.info?.album, "")
        XCTAssertNil(s.info?.artwork)
        // a new non-diff payload replaces everything
        _ = s.feed(line(#"{"type":"data","diff":false,"payload":{"title":"Other","bundleIdentifier":"b","playing":true}}"#))
        XCTAssertEqual(s.info?.title, "Other"); XCTAssertEqual(s.info?.artist, ""); XCTAssertNil(s.info?.duration)
    }

    func testEmptyPayloadMeansNothingPlaying() {
        var s = NowPlayingStream()
        _ = s.feed(line(Self.full))
        XCTAssertTrue(s.feed(line(#"{"type":"data","diff":false,"payload":{}}"#)))
        XCTAssertNil(s.info)
    }

    func testBadLinesAreIgnored() {
        var s = NowPlayingStream()
        _ = s.feed(line(Self.full))
        XCTAssertFalse(s.feed(line("not json")))
        XCTAssertFalse(s.feed(line(#"{"type":"other"}"#)))
        XCTAssertFalse(s.feed(line("")))
        XCTAssertEqual(s.info?.title, "Made Up Song")
    }

    func testSecondsKeysWithoutMicros() {
        var s = NowPlayingStream()
        _ = s.feed(line(#"{"type":"data","diff":false,"payload":{"title":"T","bundleIdentifier":"b","playing":true,"duration":180.5,"elapsedTime":12.25,"timestamp":"2023-11-14T22:13:20Z"}}"#))
        XCTAssertEqual(s.info?.duration, 180.5); XCTAssertEqual(s.info?.elapsed, 12.25)
        XCTAssertEqual(s.info?.timestamp ?? 0, 1_700_000_000, accuracy: 0.001)
    }

    func testPositionExtrapolation() {
        var i = NowPlayingInfo(title: "T", artist: "A", album: "", bundleID: "b", duration: 200, elapsed: 40, timestamp: 1000, rate: 1, playing: true, artwork: nil)
        XCTAssertEqual(i.position(at: 1000), 40, accuracy: 1e-9)
        XCTAssertEqual(i.position(at: 1005.5), 45.5, accuracy: 1e-9)
        XCTAssertEqual(i.position(at: 2000), 200, accuracy: 1e-9)          // clamped to the length
        XCTAssertEqual(i.position(at: 990), 30, accuracy: 1e-9)
        i.rate = 2
        XCTAssertEqual(i.position(at: 1005), 50, accuracy: 1e-9)
        i.rate = 0                                                         // playing but rate missing/0: assume 1x
        XCTAssertEqual(i.position(at: 1005), 45, accuracy: 1e-9)
        i.playing = false
        XCTAssertEqual(i.position(at: 1005), 40, accuracy: 1e-9)          // paused: frozen
        i.playing = true; i.duration = nil
        XCTAssertEqual(i.position(at: 5000), 4040, accuracy: 1e-9)
        i.timestamp = nil
        XCTAssertEqual(i.position(at: 5000), 40, accuracy: 1e-9)
    }

    func testTrackIdentity() {
        let a = NowPlayingInfo(title: "T", artist: "A", album: "", bundleID: "b", duration: 200.2, elapsed: 1, timestamp: 1, rate: 1, playing: true, artwork: nil)
        var b = a; b.elapsed = 99; b.playing = false
        XCTAssertEqual(a.trackKey, b.trackKey)
        b.title = "U"
        XCTAssertNotEqual(a.trackKey, b.trackKey)
    }

    func testRestartBackoff() {
        XCTAssertEqual(NowPlayingSource.backoff(failures: 0), 1)
        XCTAssertEqual(NowPlayingSource.backoff(failures: 1), 2)
        XCTAssertEqual(NowPlayingSource.backoff(failures: 3), 8)
        XCTAssertEqual(NowPlayingSource.backoff(failures: 10), 30)
    }
}
