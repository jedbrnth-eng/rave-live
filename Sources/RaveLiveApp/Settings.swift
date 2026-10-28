// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit

/// What sits on top of the visuals in the main window. None of it ever reaches Syphon or the output display.
enum OverlayLevel: Int, CaseIterable {
    case clean, status, full
    var title: String { ["Off (clean picture)", "Status line + mode bar", "Full Control HUD"][rawValue] }
    /// H key cycles status -> full -> clean -> status.
    var next: OverlayLevel { OverlayLevel(rawValue: (rawValue + 1) % Self.allCases.count)! }
}

/// Saved preferences (UserDefaults). Command-line flags always win, and test runs (`--autoquit`,
/// `--factory-settings`) start from the defaults and never save, so benchmarks stay reproducible.
struct Prefs {
    static let lastUsedMode = -1
    static let shared = Prefs(defaults: .standard,
                              frozen: CommandLine.arguments.contains("--autoquit") || CommandLine.arguments.contains("--factory-settings"))

    let defaults: UserDefaults
    /// Read the built-in defaults and ignore writes.
    let frozen: Bool

    private func int(_ k: String, _ def: Int) -> Int { frozen ? def : (defaults.object(forKey: k) as? Int ?? def) }
    private func bool(_ k: String, _ def: Bool) -> Bool { frozen ? def : (defaults.object(forKey: k) as? Bool ?? def) }
    private func set(_ v: Any, _ k: String) { if !frozen { defaults.set(v, forKey: k) } }

    var overlay: OverlayLevel {
        get { OverlayLevel(rawValue: int("overlayLevel", OverlayLevel.status.rawValue)) ?? .status }
        nonmutating set { set(newValue.rawValue, "overlayLevel") }
    }
    /// Renderer.Mode raw value, or `lastUsedMode`.
    var startMode: Int {
        get { int("startMode", Renderer.Mode.show.rawValue) }
        nonmutating set { set(newValue, "startMode") }
    }
    var lastMode: Int {
        get { int("lastMode", Renderer.Mode.show.rawValue) }
        nonmutating set { set(newValue, "lastMode") }
    }
    var startFullscreen: Bool {
        get { bool("startFullscreen", false) }
        nonmutating set { set(newValue, "startFullscreen") }
    }
    var intensity: Int {
        get { int("intensity", Renderer.Intensity.normal.rawValue) }
        nonmutating set { set(newValue, "intensity") }
    }
    var strobe: Bool {
        get { bool("strobeEnabled", true) }
        nonmutating set { set(newValue, "strobeEnabled") }
    }
    /// Visual sync trim in whole milliseconds (+ = visuals later), clamped to ±500.
    var offsetMs: Int {
        get { max(-500, min(500, int("syncOffsetMs", 0))) }
        nonmutating set { set(max(-500, min(500, newValue)), "syncOffsetMs") }
    }

    /// Synced lyrics overlay. Off for new users: it sends the playing track's title and artist to lrclib.net.
    var lyricsEnabled: Bool {
        get { bool("lyricsEnabled", false) }
        nonmutating set { set(newValue, "lyricsEnabled") }
    }
    /// Now Playing card (local only, no network).
    var playerCard: Bool {
        get { bool("playerCard", true) }
        nonmutating set { set(newValue, "playerCard") }
    }
    /// 0 small, 1 medium, 2 large.
    var lyricsSize: Int {
        get { max(0, min(2, int("lyricsSize", 1))) }
        nonmutating set { set(max(0, min(2, newValue)), "lyricsSize") }
    }
    /// Lyrics timing trim in ms (+ = lyrics later), clamped to ±1000.
    var lyricsOffsetMs: Int {
        get { max(-1000, min(1000, int("lyricsOffsetMs", 0))) }
        nonmutating set { set(max(-1000, min(1000, newValue)), "lyricsOffsetMs") }
    }

    /// The mode to open in when no mode flag was given.
    var launchMode: Int {
        let m = startMode == Self.lastUsedMode ? lastMode : startMode
        return (0..<Renderer.Mode.allCases.count).contains(m) ? m : Renderer.Mode.show.rawValue
    }

    func reset() {
        guard !frozen else { return }
        for k in ["overlayLevel", "startMode", "lastMode", "startFullscreen", "intensity", "strobeEnabled", "syncOffsetMs",
                  "lyricsEnabled", "playerCard", "lyricsSize", "lyricsOffsetMs"] { defaults.removeObject(forKey: k) }
    }
}

/// RAVE LIVE > Settings… (Cmd ,): one place for what used to be spread across keys and menus.
/// Every control acts immediately and is saved.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: AppDelegate?
    private let overlay = NSPopUpButton()
    private let startMode = NSPopUpButton()
    private let fullscreen = NSButton(checkboxWithTitle: "Open in fullscreen", target: nil, action: nil)
    private let intensity = NSSegmentedControl(labels: Renderer.Intensity.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let strobe = NSButton(checkboxWithTitle: "Strobe effects (max 3 flashes per second)", target: nil, action: nil)
    private let offset = NSSlider(value: 0, minValue: -250, maxValue: 250, target: nil, action: nil)
    private let offsetLabel = NSTextField(labelWithString: "")
    private let quality = NSPopUpButton()
    private let audioSource = NSPopUpButton()
    private let lyricsBox = NSButton(checkboxWithTitle: "Show synced lyrics for the playing song", target: nil, action: nil)
    private let cardBox = NSButton(checkboxWithTitle: "Show the Now Playing card (bottom left, hides when the mouse rests)", target: nil, action: nil)
    private let lyricsSize = NSSegmentedControl(labels: ["Small", "Medium", "Large"], trackingMode: .selectOne, target: nil, action: nil)
    private let lyricsOffset = NSSlider(value: 0, minValue: -1000, maxValue: 1000, target: nil, action: nil)
    private let lyricsOffsetLabel = NSTextField(labelWithString: "")
    private let nowPlayingNote = NSTextField(wrappingLabelWithString: "")

    init(app: AppDelegate) {
        self.app = app
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "RAVE LIVE Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        refresh()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.alignment = .right; l.font = .systemFont(ofSize: 13, weight: .medium); return l
    }
    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 360; return l
    }

    private func build() {
        overlay.addItems(withTitles: OverlayLevel.allCases.map(\.title))
        startMode.addItems(withTitles: ["Last used"] + Renderer.Mode.allCases.map(\.title))
        let offsetRow = NSStackView(views: [offset, offsetLabel]); offset.widthAnchor.constraint(equalToConstant: 240).isActive = true
        offsetLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetAll(_:)))
        let lyricsOffsetRow = NSStackView(views: [lyricsOffset, lyricsOffsetLabel]); lyricsOffset.widthAnchor.constraint(equalToConstant: 240).isActive = true
        lyricsOffsetLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        nowPlayingNote.font = .systemFont(ofSize: 11); nowPlayingNote.textColor = .secondaryLabelColor; nowPlayingNote.preferredMaxLayoutWidth = 400

        let rows: [[NSView]] = [
            [label("HUD"), overlay],
            [NSGridCell.emptyContentView, note("H cycles status → full → off while playing. Never shown on Syphon or the output display.")],
            [label("Open in"), startMode],
            [NSGridCell.emptyContentView, fullscreen],
            [label("Intensity"), intensity],
            [NSGridCell.emptyContentView, strobe],
            [label("Audio"), audioSource],
            [label("Quality"), quality],
            [label("Visual sync"), offsetRow],
            [NSGridCell.emptyContentView, note("Bluetooth speakers or a long cable run? Move the visuals later until kicks and flashes line up. Keys , and . nudge by 10 ms.")],
            [label("Lyrics"), lyricsBox],
            [NSGridCell.emptyContentView, note("While this is on, the playing track's title, artist, album and length are looked up on lrclib.net (a free lyrics database). Remixes and edits are never looked up and show no lyrics. Main window only. Y toggles.")],
            [label("Lyrics size"), lyricsSize],
            [label("Lyrics timing"), lyricsOffsetRow],
            [NSGridCell.emptyContentView, note("Lyrics early or late? Keys - and = move them by 50 ms.")],
            [label("Player card"), cardBox],
            [NSGridCell.emptyContentView, nowPlayingNote],
            [NSGridCell.emptyContentView, reset],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10; grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let cv = window!.contentView!
        cv.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: cv.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor, constant: -22),
        ])
        for (c, sel) in [(overlay, #selector(overlayChanged(_:))), (startMode, #selector(startModeChanged(_:))), (quality, #selector(qualityChanged(_:))),
                         (audioSource, #selector(audioChanged(_:)))] as [(NSPopUpButton, Selector)] { c.target = self; c.action = sel }
        fullscreen.target = self; fullscreen.action = #selector(fullscreenChanged(_:))
        intensity.target = self; intensity.action = #selector(intensityChanged(_:))
        strobe.target = self; strobe.action = #selector(strobeChanged(_:))
        offset.target = self; offset.action = #selector(offsetChanged(_:)); offset.isContinuous = true
        lyricsBox.target = self; lyricsBox.action = #selector(lyricsChanged(_:))
        cardBox.target = self; cardBox.action = #selector(cardChanged(_:))
        lyricsSize.target = self; lyricsSize.action = #selector(lyricsSizeChanged(_:))
        lyricsOffset.target = self; lyricsOffset.action = #selector(lyricsOffsetChanged(_:)); lyricsOffset.isContinuous = true
    }

    /// Pull the live state into the controls (keys, MIDI and menus change the same things).
    func refresh() {
        guard let app, let r = app.renderer else { return }
        let p = Prefs.shared
        overlay.selectItem(at: app.vj.overlay.rawValue)
        startMode.selectItem(at: p.startMode == Prefs.lastUsedMode ? 0 : p.startMode + 1)
        fullscreen.state = p.startFullscreen ? .on : .off
        intensity.selectedSegment = r.intensity.rawValue
        strobe.state = r.strobeEnabled ? .on : .off
        let ms = Int((r.userOffset * 1000).rounded())
        offset.doubleValue = Double(ms)
        offsetLabel.stringValue = ms == 0 ? "0 ms" : String(format: "%+d ms %@", ms, ms > 0 ? "later" : "earlier")
        quality.removeAllItems()
        for o in QualityController.shared.options { quality.addItem(withTitle: o.title); quality.lastItem?.representedObject = o.key }
        quality.selectItem(at: QualityController.shared.options.firstIndex { $0.key == QualityController.shared.choice } ?? 0)
        audioSource.removeAllItems()
        for o in AudioMenu.shared.options() {
            audioSource.addItem(withTitle: o.title); audioSource.lastItem?.representedObject = o.key; audioSource.lastItem?.isEnabled = o.enabled
        }
        audioSource.autoenablesItems = false
        audioSource.selectItem(at: AudioMenu.shared.options().firstIndex { $0.current } ?? 0)
        if let l = app.lyrics {
            let ok = l.source.adapter != nil
            lyricsBox.state = l.lyricsOn ? .on : .off; lyricsBox.isEnabled = ok
            cardBox.state = l.cardOn ? .on : .off; cardBox.isEnabled = ok
            lyricsSize.selectedSegment = l.size
            lyricsOffset.doubleValue = Double(l.offsetMs)
            lyricsOffsetLabel.stringValue = Self.msText(l.offsetMs)
            nowPlayingNote.stringValue = l.adapterNote
            nowPlayingNote.textColor = ok ? .secondaryLabelColor : .systemOrange
        }
    }

    static func msText(_ ms: Int) -> String { ms == 0 ? "0 ms" : String(format: "%+d ms %@", ms, ms > 0 ? "later" : "earlier") }

    func show() { refresh(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowDidBecomeKey(_ n: Notification) { refresh() }
    func windowWillClose(_ n: Notification) { app?.window.makeFirstResponder(app?.view) }

    @objc private func overlayChanged(_ s: NSPopUpButton) { app?.vj.setOverlay(OverlayLevel(rawValue: s.indexOfSelectedItem) ?? .status) }
    @objc private func startModeChanged(_ s: NSPopUpButton) { Prefs.shared.startMode = s.indexOfSelectedItem == 0 ? Prefs.lastUsedMode : s.indexOfSelectedItem - 1 }
    @objc private func fullscreenChanged(_ s: NSButton) { Prefs.shared.startFullscreen = s.state == .on }
    @objc private func intensityChanged(_ s: NSSegmentedControl) {
        guard let it = Renderer.Intensity(rawValue: s.selectedSegment) else { return }
        app?.renderer.intensity = it; Prefs.shared.intensity = it.rawValue
    }
    @objc private func strobeChanged(_ s: NSButton) { app?.renderer.strobeEnabled = s.state == .on; Prefs.shared.strobe = s.state == .on }
    @objc private func offsetChanged(_ s: NSSlider) {
        let ms = Int((s.doubleValue / 5).rounded()) * 5
        app?.renderer.userOffset = Double(ms) / 1000; Prefs.shared.offsetMs = ms
        offsetLabel.stringValue = ms == 0 ? "0 ms" : String(format: "%+d ms %@", ms, ms > 0 ? "later" : "earlier")
    }
    @objc private func lyricsChanged(_ s: NSButton) { app?.lyrics?.setLyrics(s.state == .on); refresh() }
    @objc private func cardChanged(_ s: NSButton) { app?.lyrics?.setCard(s.state == .on); refresh() }
    @objc private func lyricsSizeChanged(_ s: NSSegmentedControl) { app?.lyrics?.setSize(s.selectedSegment) }
    @objc private func lyricsOffsetChanged(_ s: NSSlider) {
        let ms = Int((s.doubleValue / 10).rounded()) * 10
        app?.lyrics?.setOffset(ms)
        lyricsOffsetLabel.stringValue = Self.msText(ms)
    }
    @objc private func qualityChanged(_ s: NSPopUpButton) { if let k = s.selectedItem?.representedObject as? String { QualityController.shared.select(k) } }
    @objc private func audioChanged(_ s: NSPopUpButton) { if let k = s.selectedItem?.representedObject as? String { AudioMenu.shared.pick(key: k) } }
    @objc private func resetAll(_ b: NSButton) {
        Prefs.shared.reset()
        guard let app, let r = app.renderer else { return }
        r.intensity = .normal; r.strobeEnabled = true; r.userOffset = 0
        QualityController.shared.select("auto")
        app.vj.setOverlay(.status)
        app.lyrics?.resetToDefaults()
        refresh()
    }
}
