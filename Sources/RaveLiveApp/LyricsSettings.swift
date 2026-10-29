// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit

/// The lyric settings, one source of truth for the Y / N / - / = keys, the Settings window and the overlay.
/// Every change is saved (through `Prefs`, so test runs never save) and announced to every observer, so the Settings
/// switch follows the Y key and the other way round.
final class LyricsSettingsModel {
    struct State: Equatable {
        var on: Bool, card: Bool, style: LyricStyle, position: LyricPosition, size: Int, offsetMs: Int
    }
    private let prefs: Prefs
    private(set) var state: State
    private var observers: [(id: Int, f: (State) -> Void)] = []
    private var nextID = 0

    init(prefs: Prefs, initial: State? = nil) {
        self.prefs = prefs
        state = initial ?? State(on: prefs.lyricsEnabled, card: prefs.playerCard, style: prefs.lyricsStyle, position: prefs.lyricsPosition,
                                 size: prefs.lyricsSize, offsetMs: prefs.lyricsOffsetMs)
    }

    @discardableResult func observe(_ f: @escaping (State) -> Void) -> Int {
        nextID += 1; observers.append((nextID, f)); return nextID
    }
    func remove(_ id: Int) { observers.removeAll { $0.id == id } }

    private func change(save: Bool, _ body: (inout State) -> Void) {
        var s = state
        body(&s)
        s.size = max(0, min(2, s.size))
        s.offsetMs = max(-1000, min(1000, s.offsetMs))
        guard s != state else { return }
        state = s
        if save {
            prefs.lyricsEnabled = s.on; prefs.playerCard = s.card; prefs.lyricsStyle = s.style; prefs.lyricsPosition = s.position
            prefs.lyricsSize = s.size; prefs.lyricsOffsetMs = s.offsetMs
        }
        for o in observers { o.f(s) }
    }

    func setOn(_ v: Bool, save: Bool = true) { change(save: save) { $0.on = v } }
    func toggle() { setOn(!state.on) }
    func setCard(_ v: Bool, save: Bool = true) { change(save: save) { $0.card = v } }
    func setStyle(_ v: LyricStyle) { change(save: true) { $0.style = v } }
    func setPosition(_ v: LyricPosition) { change(save: true) { $0.position = v } }
    func setSize(_ v: Int) { change(save: true) { $0.size = v } }
    func setOffset(_ ms: Int) { change(save: true) { $0.offsetMs = ms } }
    /// Settings → Restore Defaults: back to the built-in values without saving (Prefs.reset already removed the keys).
    func resetToDefaults() {
        change(save: false) { $0 = State(on: false, card: true, style: .default, position: .default, size: 1, offsetMs: 0) }
    }
}

/// Settings → Lyrics: an on/off switch (like the HUD control, in sync with Y), style, position, size and timing.
final class LyricsSettingsSection {
    let enabled = NSSwitch()
    let enabledLabel = NSTextField(labelWithString: "")
    let style = NSPopUpButton()
    let styleNote = NSTextField(wrappingLabelWithString: "")
    let position = NSSegmentedControl(labels: LyricPosition.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let size = NSSegmentedControl(labels: ["Small", "Medium", "Large"], trackingMode: .selectOne, target: nil, action: nil)
    let offset = NSSlider(value: 0, minValue: -1000, maxValue: 1000, target: nil, action: nil)
    let offsetLabel = NSTextField(labelWithString: "")
    let card = NSButton(checkboxWithTitle: "Show the Now Playing card (bottom left, hides when the mouse rests)", target: nil, action: nil)
    private let model: LyricsSettingsModel
    private var token = 0
    private let target = Target()

    private final class Target: NSObject {
        weak var section: LyricsSettingsSection?
        @objc func enabledChanged(_ s: NSSwitch) { section?.model.setOn(s.state == .on) }
        @objc func styleChanged(_ s: NSPopUpButton) { section?.model.setStyle(LyricStyle.allCases[max(0, s.indexOfSelectedItem)]) }
        @objc func positionChanged(_ s: NSSegmentedControl) { section?.model.setPosition(LyricPosition.allCases[max(0, s.selectedSegment)]) }
        @objc func sizeChanged(_ s: NSSegmentedControl) { section?.model.setSize(s.selectedSegment) }
        @objc func offsetChanged(_ s: NSSlider) { section?.model.setOffset(Int((s.doubleValue / 10).rounded()) * 10) }
        @objc func cardChanged(_ s: NSButton) { section?.model.setCard(s.state == .on) }
    }

    init(model: LyricsSettingsModel) {
        self.model = model
        target.section = self
        style.addItems(withTitles: LyricStyle.allCases.map(\.title))
        styleNote.font = .systemFont(ofSize: 11); styleNote.textColor = .secondaryLabelColor; styleNote.preferredMaxLayoutWidth = 360
        offsetLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        offset.isContinuous = true
        enabled.target = target; enabled.action = #selector(Target.enabledChanged(_:))
        style.target = target; style.action = #selector(Target.styleChanged(_:))
        position.target = target; position.action = #selector(Target.positionChanged(_:))
        size.target = target; size.action = #selector(Target.sizeChanged(_:))
        offset.target = target; offset.action = #selector(Target.offsetChanged(_:))
        card.target = target; card.action = #selector(Target.cardChanged(_:))
        token = model.observe { [weak self] s in self?.show(s) }
        show(model.state)
    }
    deinit { model.remove(token) }

    func show(_ s: LyricsSettingsModel.State) {
        enabled.state = s.on ? .on : .off
        enabledLabel.stringValue = s.on ? "On (Y)" : "Off (Y)"
        style.selectItem(at: LyricStyle.allCases.firstIndex(of: s.style) ?? 0)
        styleNote.stringValue = s.style.blurb
        position.selectedSegment = LyricPosition.allCases.firstIndex(of: s.position) ?? 0
        size.selectedSegment = s.size
        offset.doubleValue = Double(s.offsetMs)
        offsetLabel.stringValue = SettingsWindowController.msText(s.offsetMs)
        card.state = s.card ? .on : .off
    }

    /// Greyed out when this build has no Now Playing reader.
    func setAvailable(_ ok: Bool) {
        for c in [enabled, style, position, size, offset, card] as [NSControl] { c.isEnabled = ok }
    }
}
