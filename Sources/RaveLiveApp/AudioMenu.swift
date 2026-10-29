// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import RaveAudio

/// The "Audio" menu: System Audio (macOS 13+) or any CoreAudio input device (mic, interface, DJ mixer,
/// BlackHole/Loopback). The pick is remembered; the list refreshes when devices come and go.
final class AudioMenu: NSObject, NSMenuDelegate {
    static let shared = AudioMenu()
    static let compatibilityURL = URL(string: "https://github.com/jedbrnth-eng/rave-live/blob/main/docs/COMPATIBILITY.md")!

    private weak var audio: AudioEngine?
    private let menu = NSMenu(title: "Audio")

    /// Source to start with: `--mic`, `--input "<name substring>"` (testing; not saved), else the saved pick.
    static func initialSource(_ args: [String]) -> InputSource {
        if let i = args.firstIndex(of: "--input"), args.count > i + 1 {
            let q = args[i + 1]
            if let d = AudioInputDevice.matching(q) { return .device(d.uid) }
            NSLog("RAVE LIVE: no input device matches \"%@\"; available: %@", q, AudioInputDevice.all().map { $0.name }.joined(separator: ", "))
            return .mic
        }
        if args.contains("--mic") { return .mic }
        return InputSource.saved
    }

    func menuItem(audio: AudioEngine) -> NSMenuItem {
        self.audio = audio
        let item = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        menu.autoenablesItems = false
        menu.delegate = self
        item.submenu = menu
        audio.onDevicesChanged = { [weak self] in self?.rebuild() }
        rebuild()
        if let i = CommandLine.arguments.firstIndex(of: "--audio-menu-shot"), CommandLine.arguments.count > i + 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.shoot(to: CommandLine.arguments[i + 1]) }
        }
        return item
    }

    /// Test hook (`--audio-menu-shot <png>`): pops the Audio menu up over the window and renders this app's
    /// menu window into a PNG in-process (no screen capture, no permission needed).
    private func shoot(to path: String) {
        guard let view = NSApp.mainWindow?.contentView ?? NSApp.windows.first?.contentView else { return }
        // The menu tracks in its own run loop mode, so use a common-modes timer rather than GCD.
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            defer { self?.menu.cancelTracking() }
            let wins = NSApp.windows.filter { $0.isVisible && $0.level.rawValue > NSWindow.Level.normal.rawValue }
            NSLog("RAVE LIVE: menu shot candidates: %@", wins.map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))
            guard let w = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  let root = w.contentView?.superview ?? w.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { NSLog("RAVE LIVE: menu shot: no menu window"); return }
            root.cacheDisplay(in: root.bounds, to: rep)
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NSLog("RAVE LIVE: menu shot saved to %@", path)
            } catch { NSLog("RAVE LIVE: menu shot failed: %@", error.localizedDescription) }
        }
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 60, y: view.bounds.height - 60), in: view)
    }

    func select(_ src: InputSource) {
        InputSource.saved = src
        guard let audio else { return }
        Task { @MainActor [weak self] in
            await audio.start(src)
            self?.rebuild()
        }
    }

    /// M key: toggle between system audio and the last-used input device.
    func toggle() {
        guard let audio else { return }
        select(audio.source == .system ? .device(Prefs.shared.lastInputDevice.flatMap { $0.isEmpty ? nil : $0 }) : .system)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        let current = audio?.source ?? InputSource.saved
        menu.removeAllItems()
        let sys = NSMenuItem(title: "System Audio", action: #selector(pick(_:)), keyEquivalent: "")
        sys.representedObject = InputSource.system.key
        sys.state = current == .system ? .on : .off
        if !SystemAudio.isSupported {
            sys.isEnabled = false
            sys.title = "System Audio (needs macOS 13)"
            sys.toolTip = "macOS 12 can't capture system audio directly. Pick an input below, or install the free BlackHole loopback driver, send your music to it and pick it here."
        } else {
            sys.toolTip = "What your Mac is playing (needs Screen & System Audio Recording permission)."
        }
        menu.addItem(sys)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Input Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let def = AudioInputDevice.defaultInput()
        let defItem = NSMenuItem(title: "Default Input" + (def.map { " (\($0.name))" } ?? ""), action: #selector(pick(_:)), keyEquivalent: "")
        defItem.representedObject = InputSource.mic.key
        defItem.state = current == .mic ? .on : .off
        defItem.indentationLevel = 1
        menu.addItem(defItem)
        let devices = AudioInputDevice.all()
        for d in devices {
            let it = NSMenuItem(title: d.name, action: #selector(pick(_:)), keyEquivalent: "")
            it.representedObject = InputSource.device(d.uid).key
            it.state = current == .device(d.uid) ? .on : .off
            it.toolTip = "\(d.channels) input channel\(d.channels == 1 ? "" : "s")"
            it.indentationLevel = 1
            menu.addItem(it)
        }
        if devices.isEmpty {
            let none = NSMenuItem(title: "No input devices found", action: nil, keyEquivalent: "")
            none.isEnabled = false; none.indentationLevel = 1
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let help = NSMenuItem(title: "Visualize System Audio with BlackHole…", action: #selector(openHelp), keyEquivalent: "")
        menu.addItem(help)
        for it in menu.items where it.action != nil { it.target = self }
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        pick(key: key)
    }

    /// Same as choosing an entry in the Audio menu (also used by the Settings window).
    func pick(key: String) {
        let src = InputSource(key: key)
        select(src)
    }

    /// The Audio menu's choices as data, for the Settings window.
    func options() -> [(key: String, title: String, enabled: Bool, current: Bool)] {
        let current = audio?.source ?? InputSource.saved
        var out: [(key: String, title: String, enabled: Bool, current: Bool)] = []
        out.append((InputSource.system.key, SystemAudio.isSupported ? "System Audio" : "System Audio (needs macOS 13)", SystemAudio.isSupported, current == .system))
        let def = AudioInputDevice.defaultInput()
        out.append((InputSource.mic.key, "Default Input" + (def.map { " (\($0.name))" } ?? ""), true, current == .mic))
        for d in AudioInputDevice.all() { out.append((InputSource.device(d.uid).key, d.name, true, current == .device(d.uid))) }
        return out
    }

    @objc private func openHelp() { NSWorkspace.shared.open(Self.compatibilityURL) }
}
