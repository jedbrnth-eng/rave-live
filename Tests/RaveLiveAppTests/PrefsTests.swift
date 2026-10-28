// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

final class PrefsTests: XCTestCase {
    private func fresh() -> UserDefaults {
        let name = "ravelive.prefs.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaults() {
        let p = Prefs(defaults: fresh(), frozen: false)
        XCTAssertEqual(p.overlay, .status)
        XCTAssertEqual(p.launchMode, Renderer.Mode.show.rawValue)
        XCTAssertEqual(p.intensity, Renderer.Intensity.normal.rawValue)
        XCTAssertTrue(p.strobe)
        XCTAssertFalse(p.startFullscreen)
        XCTAssertEqual(p.offsetMs, 0)
    }

    func testSavesAndResets() {
        let d = fresh()
        let p = Prefs(defaults: d, frozen: false)
        p.overlay = .clean; p.intensity = 0; p.strobe = false; p.offsetMs = 120; p.startFullscreen = true
        p.startMode = Renderer.Mode.aurora.rawValue
        let q = Prefs(defaults: d, frozen: false)          // a later launch
        XCTAssertEqual(q.overlay, .clean)
        XCTAssertEqual(q.intensity, 0)
        XCTAssertFalse(q.strobe)
        XCTAssertEqual(q.offsetMs, 120)
        XCTAssertTrue(q.startFullscreen)
        XCTAssertEqual(q.launchMode, Renderer.Mode.aurora.rawValue)
        q.reset()
        XCTAssertEqual(q.overlay, .status)
        XCTAssertEqual(q.offsetMs, 0)
        XCTAssertEqual(q.launchMode, Renderer.Mode.show.rawValue)
    }

    func testLastUsedMode() {
        let p = Prefs(defaults: fresh(), frozen: false)
        p.startMode = Prefs.lastUsedMode
        p.lastMode = Renderer.Mode.milkdrop.rawValue
        XCTAssertEqual(p.launchMode, Renderer.Mode.milkdrop.rawValue)
        p.lastMode = 99                                       // garbage from an older build falls back to SHOW
        XCTAssertEqual(p.launchMode, Renderer.Mode.show.rawValue)
    }

    func testOffsetIsClamped() {
        let p = Prefs(defaults: fresh(), frozen: false)
        p.offsetMs = 9000
        XCTAssertEqual(p.offsetMs, 500)
        p.offsetMs = -9000
        XCTAssertEqual(p.offsetMs, -500)
    }

    /// Test runs (--autoquit) must not read Jed's saved settings or write over them.
    func testFrozenIgnoresSavedValuesAndNeverWrites() {
        let d = fresh()
        Prefs(defaults: d, frozen: false).overlay = .clean
        let f = Prefs(defaults: d, frozen: true)
        XCTAssertEqual(f.overlay, .status)
        f.overlay = .full; f.intensity = 2
        XCTAssertEqual(d.integer(forKey: "overlayLevel"), OverlayLevel.clean.rawValue)
        XCTAssertNil(d.object(forKey: "intensity"))
        f.reset()
        XCTAssertEqual(d.integer(forKey: "overlayLevel"), OverlayLevel.clean.rawValue)
    }

    /// Lyrics send track titles to lrclib.net, so they start OFF; the player card is local only and starts on.
    func testLyricsPrefs() {
        let d = fresh()
        let p = Prefs(defaults: d, frozen: false)
        XCTAssertFalse(p.lyricsEnabled)
        XCTAssertTrue(p.playerCard)
        XCTAssertEqual(p.lyricsSize, 1)
        XCTAssertEqual(p.lyricsOffsetMs, 0)
        p.lyricsEnabled = true; p.playerCard = false; p.lyricsSize = 2; p.lyricsOffsetMs = 5000
        let q = Prefs(defaults: d, frozen: false)
        XCTAssertTrue(q.lyricsEnabled); XCTAssertFalse(q.playerCard); XCTAssertEqual(q.lyricsSize, 2)
        XCTAssertEqual(q.lyricsOffsetMs, 1000)                 // clamped to ±1000 ms
        q.lyricsOffsetMs = -4000
        XCTAssertEqual(q.lyricsOffsetMs, -1000)
        q.lyricsSize = 7
        XCTAssertEqual(q.lyricsSize, 2)
        q.reset()
        XCTAssertFalse(q.lyricsEnabled); XCTAssertTrue(q.playerCard); XCTAssertEqual(q.lyricsOffsetMs, 0)
        let f = Prefs(defaults: d, frozen: true)
        f.lyricsEnabled = true
        XCTAssertNil(d.object(forKey: "lyricsEnabled"))       // test runs never write
        XCTAssertFalse(f.lyricsEnabled)
    }

    func testHKeyCycle() {
        XCTAssertEqual(OverlayLevel.status.next, .full)
        XCTAssertEqual(OverlayLevel.full.next, .clean)
        XCTAssertEqual(OverlayLevel.clean.next, .status)
    }
}
