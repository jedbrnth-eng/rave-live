// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit

/// MILKDROP UI: the preset browser panel, the "Get presets" card shown when the mode can't run, keys and menu items.

/// Searchable preset list: favourite, name, author, category, rating. Double-click (or Return) plays a preset.
final class MilkDropBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let milk: MilkDropRenderer
    let panel: NSPanel
    private let table = NSTableView()
    private let search = NSSearchField()
    private let favOnly = NSButton(checkboxWithTitle: "Favourites only", target: nil, action: nil)
    private let info = NSTextField(labelWithString: "")
    private var rows: [MilkDropLibrary.Preset] = []
    var onPlayed: (() -> Void)?

    init(milk: MilkDropRenderer) {
        self.milk = milk
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "MilkDrop Presets"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let cv = panel.contentView!
        search.placeholderString = "Search name, author or category"
        search.delegate = self
        search.frame = NSRect(x: 12, y: 482, width: 420, height: 26); search.autoresizingMask = [.width, .minYMargin]
        favOnly.target = self; favOnly.action = #selector(reload)
        favOnly.frame = NSRect(x: 444, y: 484, width: 140, height: 22); favOnly.autoresizingMask = [.minXMargin, .minYMargin]
        let rescan = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        rescan.frame = NSRect(x: 588, y: 480, width: 80, height: 30); rescan.autoresizingMask = [.minXMargin, .minYMargin]
        let folder = NSButton(title: "Folder…", target: self, action: #selector(openFolder))
        folder.frame = NSRect(x: 668, y: 480, width: 84, height: 30); folder.autoresizingMask = [.minXMargin, .minYMargin]
        for (id, title, w) in [("fav", "★", 26.0), ("name", "Name", 300.0), ("author", "Author", 170.0), ("cat", "Category", 120.0), ("rating", "Rating", 70.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = w; table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self
        table.doubleAction = #selector(play); table.target = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 36, width: 736, height: 438))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
        info.frame = NSRect(x: 12, y: 8, width: 736, height: 20); info.autoresizingMask = [.width, .maxYMargin]
        info.textColor = .secondaryLabelColor
        for v in [search, favOnly, rescan, folder, scroll, info] as [NSView] { cv.addSubview(v) }
        reload()
    }

    func show() { reload(); panel.center(); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search) }

    @objc func reload() {
        rows = milk.library.search(search.stringValue, favoritesOnly: favOnly.state == .on)
        table.reloadData()
        info.stringValue = "\(rows.count) of \(milk.library.count) presets · \(milk.library.brokenCount) skipped as broken · double-click to play · "
            + "keys in MILKDROP: [ ] prev/next, R random, F favourite, L lock, 1-5 rate, P this list"
    }
    @objc private func rescan() { milk.library.scan(); reload() }
    @objc private func openFolder() { milk.library.openUserFolder() }
    @objc private func play() {
        let i = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard i >= 0, i < rows.count else { return }
        milk.load(rows[i], smooth: false, why: "browser")
        milk.director.manualSwitch(now: CACurrentMediaTime())
        onPlayed?()
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { if table.selectedRow < 0 && !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }; play(); return true }
        if sel == #selector(NSResponder.moveDown(_:)) { panel.makeFirstResponder(table); return true }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let p = rows[row]
        let id = col?.identifier.rawValue ?? ""
        let text: String
        switch id {
        case "fav": text = milk.library.isFavorite(p) ? "★" : ""
        case "name": text = p.name + (milk.library.brokenReason(p) != nil ? "  (broken)" : "")
        case "author": text = p.author
        case "cat": text = p.category
        default: let r = milk.library.rating(p); text = r > 0 ? String(repeating: "●", count: r) : ""
        }
        let cell = (tableView.makeView(withIdentifier: .init("c" + id), owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: ""); f.identifier = .init("c" + id); f.lineBreakMode = .byTruncatingTail; return f
        }()
        cell.stringValue = text
        return cell
    }
}

/// Shown over the MILKDROP mode when the engine or presets are missing. Never a crash: just this card.
final class MilkDropCard: NSView {
    let title = NSTextField(labelWithString: "MILKDROP")
    let message = NSTextField(wrappingLabelWithString: "")
    let get = NSButton(title: "Get MilkDrop presets…", target: nil, action: nil)
    let folder = NSButton(title: "Open preset folder…", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        layer?.cornerRadius = 14
        title.font = .systemFont(ofSize: 22, weight: .heavy); title.textColor = .white
        message.font = .systemFont(ofSize: 13); message.textColor = NSColor(white: 1, alpha: 0.8)
        title.frame = NSRect(x: 24, y: 150, width: 432, height: 30)
        message.frame = NSRect(x: 24, y: 60, width: 432, height: 84)
        get.frame = NSRect(x: 20, y: 16, width: 220, height: 32); get.bezelStyle = .rounded; get.keyEquivalent = "\r"
        folder.frame = NSRect(x: 244, y: 16, width: 200, height: 32); folder.bezelStyle = .rounded
        for v in [title, message, get, folder] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

extension AppDelegate {
    private static var milkBrowser: MilkDropBrowser?
    private static var milkCard: MilkDropCard?

    /// Command-line flags, audio feed and initial scan. Called once the renderer exists.
    func setupMilkDrop(_ args: [String]) {
        guard let r = renderer, let m = r.milk else { return }
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        if let d = arg("--milk-dir") { m.library.extraDirs.append(URL(fileURLWithPath: NSString(string: d).expandingTildeInPath)) }
        m.library.scan()
        audio.onPCM = { [weak m] b in m?.feed(b) }
        if args.contains("--milkdrop") { r.mode = .milkdrop }
        if args.contains("--no-show-milkdrop") { r.showMilkDrop = false }
        if let p = arg("--milk-preset") {
            let preset = m.library.preset(at: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath))
            m.load(preset, smooth: false, why: "cli")
            m.director.manualSwitch(now: CACurrentMediaTime())
        }
        if args.contains("--milk-lock") { m.director.locked = true }
        if let n = arg("--milk-sweep").flatMap(Int.init) {
            let secs = arg("--milk-sweep-secs").flatMap(Double.init) ?? 1.5
            let seed = arg("--milk-sweep-seed").flatMap(UInt64.init) ?? 42
            m.sweep = .init(list: m.library.sample(n, seed: seed), seconds: secs, outDir: r.snapDir)
            try? FileManager.default.createDirectory(at: r.snapDir, withIntermediateDirectories: true)
        }
        NSLog("RAVE LIVE: MilkDrop %@, %d presets", m.ready ? "ready" : m.problem, m.library.count)
    }

    func addMilkDropMenu(to vm: NSMenu) {
        vm.addItem(.separator())
        let b = NSMenuItem(title: "MilkDrop Presets…", action: #selector(milkMenuBrowser(_:)), keyEquivalent: "p"); b.target = self; vm.addItem(b)
        let g = NSMenuItem(title: "Get MilkDrop Presets…", action: #selector(milkMenuGet(_:)), keyEquivalent: ""); g.target = self; vm.addItem(g)
        let o = NSMenuItem(title: "Open MilkDrop Preset Folder…", action: #selector(milkMenuFolder(_:)), keyEquivalent: ""); o.target = self; vm.addItem(o)
    }
    @objc func milkMenuBrowser(_ i: NSMenuItem?) {
        guard let m = renderer?.milk else { return }
        if Self.milkBrowser == nil {
            Self.milkBrowser = MilkDropBrowser(milk: m)
            Self.milkBrowser?.onPlayed = { [weak self] in if self?.renderer.mode != .milkdrop { self?.setMode(.milkdrop) } }
        }
        Self.milkBrowser?.show()
    }
    @objc func milkMenuGet(_ i: NSMenuItem?) {
        guard let m = renderer?.milk else { return }
        m.library.confirmAndDownload { [weak self] ok in
            DispatchQueue.main.async {
                self?.updateMilkCard()
                Self.milkBrowser?.reload()
                if ok { m.loadNext(loud: false, smooth: false, blendSeconds: 0, why: "downloaded") }
            }
        }
        updateMilkCard()
    }
    @objc func milkMenuFolder(_ i: NSMenuItem?) { renderer?.milk?.library.openUserFolder() }

    /// Keys in MILKDROP mode. Returns true when handled (F favourites here; fullscreen stays on cmd-F).
    func milkKey(_ e: NSEvent) -> Bool {
        guard let r = renderer, let m = r.milk, r.mode == .milkdrop, !e.modifierFlags.contains(.command) else { return false }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let now = CACurrentMediaTime()
        switch ch {
        case "]", "[":
            m.step(ch == "]" ? 1 : -1); m.director.manualSwitch(now: now)
        case "r":
            m.loadNext(loud: false, smooth: true, blendSeconds: 1.5, why: "random"); m.director.manualSwitch(now: now)
        case "f":
            if let p = m.current { let on = m.library.toggleFavorite(p); flashStatus(on ? "★ Favourite: \(p.name)" : "Removed from favourites: \(p.name)") }
        case "l":
            m.director.locked.toggle(); flashStatus(m.director.locked ? "Preset locked (L to unlock)" : "Preset unlocked: changes follow the beat again")
        case "p": milkMenuBrowser(nil)
        case "0", "1", "2", "3", "4", "5":
            if let p = m.current { m.library.setRating(p, Int(ch)!); flashStatus(ch == "0" ? "Rating cleared" : "Rated \(ch)/5: \(p.name)") }
        default: return false
        }
        Self.milkBrowser?.reload()
        r.metrics.event("milk:key \(ch)", at: now)
        return true
    }

    private func flashStatus(_ s: String) {
        status.stringValue = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.status.stringValue == s { self?.status.stringValue = "" } }
    }

    /// Show/hide the "Get presets" card (main thread; called from the HUD tick and after downloads).
    func updateMilkCard() {
        guard let r = renderer, let m = r.milk, let cv = window.contentView else { return }
        var text = m.problem
        var busy = false
        switch m.library.download {
        case .downloading(let f): text = String(format: "Downloading presets… %.0f%%", f * 100); busy = true
        case .unpacking: text = "Unpacking presets…"; busy = true
        case .failed(let e): text = "Download failed: \(e). " + text
        default: break
        }
        let show = r.mode == .milkdrop && (!m.ready || busy)
        if show && Self.milkCard == nil {
            let c = MilkDropCard(frame: NSRect(x: 0, y: 0, width: 480, height: 196))
            c.get.target = self; c.get.action = #selector(milkMenuGet(_:))
            c.folder.target = self; c.folder.action = #selector(milkMenuFolder(_:))
            c.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            cv.addSubview(c, positioned: .above, relativeTo: view)
            Self.milkCard = c
        }
        guard let c = Self.milkCard else { return }
        c.isHidden = !show
        if show {
            c.frame.origin = NSPoint(x: (cv.bounds.width - c.frame.width) / 2, y: (cv.bounds.height - c.frame.height) / 2)
            let engineMissing = m.lib == nil
            c.message.stringValue = text + (engineMissing ? "" : "\n\n" + MilkDropLibrary.packInfo + ". Or drop your own .milk files into the preset folder.")
            c.get.isEnabled = !busy && !engineMissing
        }
    }
}
