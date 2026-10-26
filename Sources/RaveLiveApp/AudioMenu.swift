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
        return item
    }

    /// Switch source and remember it (menu and the M key).
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
        select(audio.source == .system ? .device(UserDefaults.standard.string(forKey: "lastInputDevice")) : .system)
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
        let src = InputSource(key: key)
        if case .device(let uid) = src { UserDefaults.standard.set(uid, forKey: "lastInputDevice") }
        select(src)
    }

    @objc private func openHelp() { NSWorkspace.shared.open(Self.compatibilityURL) }
}
