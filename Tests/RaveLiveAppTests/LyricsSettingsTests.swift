// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
import AppKit
@testable import RaveLiveApp

/// Jed (10-29 19:58): "add a button to turn lyrics on and off in Settings, same as the HUD", plus a style setting.
final class LyricsSettingsTests: XCTestCase {
    private func fresh() -> (UserDefaults, Prefs) {
        let name = "ravelive.lyricsettings.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (d, Prefs(defaults: d, frozen: false))
    }

    /// The Y key flips the model; the Settings switch follows, and the choice is saved.
    func testYKeyUpdatesTheSettingsSwitchAndPersists() {
        let (d, p) = fresh()
        let m = LyricsSettingsModel(prefs: p)
        let s = LyricsSettingsSection(model: m)
        XCTAssertEqual(s.enabled.state, .off)
        m.toggle()                                              // what Y does
        XCTAssertEqual(s.enabled.state, .on)
        XCTAssertTrue(Prefs(defaults: d, frozen: false).lyricsEnabled)
        m.toggle()
        XCTAssertEqual(s.enabled.state, .off)
        XCTAssertFalse(Prefs(defaults: d, frozen: false).lyricsEnabled)
    }

    /// The Settings switch changes what the overlay and Y see, and is saved.
    func testSettingsSwitchUpdatesTheAppAndPersists() {
        let (d, p) = fresh()
        let m = LyricsSettingsModel(prefs: p)
        let s = LyricsSettingsSection(model: m)
        var seen: [Bool] = []
        m.observe { seen.append($0.on) }                        // the lyrics controller listens the same way
        s.enabled.state = .on
        XCTAssertTrue(s.enabled.sendAction(s.enabled.action, to: s.enabled.target))
        XCTAssertTrue(m.state.on)
        XCTAssertEqual(seen, [true])
        XCTAssertTrue(Prefs(defaults: d, frozen: false).lyricsEnabled)
    }

    func testStylePositionSizeOffsetFromSettings() {
        let (d, p) = fresh()
        let m = LyricsSettingsModel(prefs: p)
        let s = LyricsSettingsSection(model: m)
        XCTAssertEqual(s.style.numberOfItems, LyricStyle.allCases.count)
        XCTAssertEqual(s.style.titleOfSelectedItem, LyricStyle.clean.title)
        s.style.selectItem(at: LyricStyle.allCases.firstIndex(of: .neon)!)
        s.style.sendAction(s.style.action, to: s.style.target)
        s.position.selectedSegment = 1; s.position.sendAction(s.position.action, to: s.position.target)
        s.size.selectedSegment = 2; s.size.sendAction(s.size.action, to: s.size.target)
        s.offset.doubleValue = 123; s.offset.sendAction(s.offset.action, to: s.offset.target)
        XCTAssertEqual(m.state.style, .neon)
        XCTAssertEqual(s.styleNote.stringValue, LyricStyle.neon.blurb)
        let q = Prefs(defaults: d, frozen: false)
        XCTAssertEqual(q.lyricsStyle, .neon)
        XCTAssertEqual(q.lyricsPosition, .center)
        XCTAssertEqual(q.lyricsSize, 2)
        XCTAssertEqual(q.lyricsOffsetMs, 120, "slider snaps to 10 ms")
        XCTAssertEqual(s.offsetLabel.stringValue, "+120 ms later")
        m.setOffset(-50)                                        // the - key
        XCTAssertEqual(s.offset.doubleValue, -50)
    }

    func testNoChangeNoNotificationAndClamping() {
        let (_, p) = fresh()
        let m = LyricsSettingsModel(prefs: p)
        var n = 0
        m.observe { _ in n += 1 }
        m.setOn(false)
        XCTAssertEqual(n, 0)
        m.setOffset(99_999)
        XCTAssertEqual(m.state.offsetMs, 1000)
        m.setSize(-3)
        XCTAssertEqual(m.state.size, 0)
    }

    func testTestRunsNeverSave() {
        let (d, _) = fresh()
        let m = LyricsSettingsModel(prefs: Prefs(defaults: d, frozen: true))
        m.toggle(); m.setStyle(.pop)
        XCTAssertNil(d.object(forKey: "lyricsEnabled"))
        XCTAssertNil(d.object(forKey: "lyricsStyle"))
    }

    func testRestoreDefaultsResetsTheSection() {
        let (_, p) = fresh()
        let m = LyricsSettingsModel(prefs: p)
        let s = LyricsSettingsSection(model: m)
        m.setOn(true); m.setStyle(.wave)
        m.resetToDefaults()
        XCTAssertEqual(s.enabled.state, .off)
        XCTAssertEqual(s.style.titleOfSelectedItem, LyricStyle.clean.title)
    }
}
