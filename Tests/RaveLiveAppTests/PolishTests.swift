// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

/// Review findings (2026-10-29 polish pass), each reproduced here before the fix.
final class PolishTests: XCTestCase {

    // MARK: player card fade

    /// A card that has faded out must be hidden: an invisible (alpha 0) card still caught clicks meant for the
    /// visuals and could pause the music, and window snapshots drew it at full opacity.
    func testFadedCardIsHiddenAndWakesBackUp() {
        var a: CGFloat = 1
        var hidden = false
        for _ in 0..<120 { (a, hidden) = LyricsController.cardStep(alpha: a, want: true, awake: false) }   // 4 s at 30 Hz
        XCTAssertLessThan(a, 0.02)
        XCTAssertTrue(hidden, "a faded-out card stays clickable")
        (a, hidden) = LyricsController.cardStep(alpha: a, want: true, awake: true)
        XCTAssertFalse(hidden, "mouse movement shows the card again")
        XCTAssertGreaterThan(a, 0.1)
        for _ in 0..<10 { (a, hidden) = LyricsController.cardStep(alpha: a, want: true, awake: true) }
        XCTAssertGreaterThan(a, 0.75); XCTAssertFalse(hidden)
        (a, hidden) = LyricsController.cardStep(alpha: a, want: false, awake: true)                      // card off / HUD clean
        XCTAssertTrue(hidden)
    }

    /// While the card is fading in or out it stays visible (no pop).
    func testCardVisibleWhileFading() {
        var a: CGFloat = 1
        var hidden = false
        for _ in 0..<5 { (a, hidden) = LyricsController.cardStep(alpha: a, want: true, awake: false) }
        XCTAssertGreaterThan(a, 0.3); XCTAssertFalse(hidden)
    }

    // MARK: full HUD vs the mode bar

    /// In a narrow window the full Control HUD (top right) was drawn over the mode bar (top left).
    func testFullHUDMovesBelowTheModeBarWhenTheyWouldOverlap() {
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 360)
        let modeBar = NSRect(x: 12, y: 320, width: 556, height: 28)
        let size = NSSize(width: 345, height: 150)
        let f = VJRig.hudFrame(bounds: bounds, size: size, avoid: modeBar)
        XCTAssertFalse(f.intersects(modeBar), "HUD \(f) overlaps the mode bar \(modeBar)")
        XCTAssertEqual(f.maxX, bounds.maxX - 12, accuracy: 0.5)            // still right-aligned
        XCTAssertLessThanOrEqual(f.maxY, modeBar.minY)
        // wide window: unchanged top-right placement
        let wide = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let g = VJRig.hudFrame(bounds: wide, size: size, avoid: NSRect(x: 12, y: 1040, width: 556, height: 28))
        XCTAssertEqual(g, NSRect(x: 1920 - 345 - 12, y: 1080 - 150 - 12, width: 345, height: 150))
        // mode bar hidden (HUD clean): top right
        XCTAssertEqual(VJRig.hudFrame(bounds: bounds, size: size, avoid: nil).maxY, 360 - 12, accuracy: 0.5)
    }

    // MARK: remix guard / title cleaning

    /// Sped-up, slowed, nightcore and 8D uploads play the song at another speed: never look them up.
    func testSpeedVersionsAreRemixes() {
        for t in ["Song (Sped Up)", "Song - Sped Up", "Song (Slowed + Reverb)", "Song - slowed & reverb", "Song (Nightcore)",
                  "Song [8D Audio]", "Song (sped up version)"] {
            XCTAssertTrue(TrackTitle.hasRemixMarker(t), t)
        }
        for t in ["Slowed Down", "Speed Up The Night", "Reverb Island"] { XCTAssertFalse(TrackTitle.hasRemixMarker(t), t) }
    }

    /// YouTube in a browser reports auto-generated channels as "<Artist> - Topic".
    func testTopicChannelArtist() {
        XCTAssertEqual(TrackTitle.cleanArtist("The Weeknd - Topic"), "The Weeknd")
        XCTAssertEqual(TrackTitle.primaryArtist("Peso Pluma - Topic"), "Peso Pluma")
        XCTAssertEqual(TrackTitle.cleanArtist("Topic"), "Topic")
    }

    // MARK: Now Playing numbers

    /// A non-finite or negative length must not reach `Int(...)` (trackKey, cache key, lookup) and crash the app.
    func testNonFiniteOrNegativeDurationIsIgnored() {
        var s = NowPlayingStream()
        _ = s.feed(Data(#"{"type":"data","diff":false,"payload":{"title":"T","bundleIdentifier":"b","playing":true,"durationMicros":1e400,"elapsedTimeMicros":1000000}}"#.utf8))
        XCTAssertNil(s.info?.duration)
        _ = s.info?.trackKey
        _ = s.feed(Data(#"{"type":"data","diff":false,"payload":{"title":"T","bundleIdentifier":"b","playing":true,"duration":-5}}"#.utf8))
        XCTAssertNil(s.info?.duration)
        _ = LyricsCache.key(title: "T", artist: "A", duration: .infinity)
        _ = LyricsCache.key(title: "T", artist: "A", duration: .nan)
    }
}
