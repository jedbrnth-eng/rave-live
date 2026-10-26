// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import MetalKit
import RaveAudio
import UniformTypeIdentifiers

/// VJ rig: Output menu (Syphon, send to display), Controls menu (MIDI learn, clock sync, mappings), the performer
/// Control HUD (H) and the shortcut cheat sheet (?). Overlays are AppKit views over the main window, so Syphon and
/// the output display never show them.
final class VJRig: NSObject, NSMenuDelegate {
    private weak var app: AppDelegate?
    private var renderer: Renderer? { app?.renderer }
    private(set) var output: FrameOutput?
    private(set) var outputWindow: OutputWindow?
    private(set) var midi: MidiControl!
    private let hudView = OverlayPanel()
    private let cheatView = OverlayPanel(alpha: 0.82)
    private var learnPanel: MidiLearnPanel?
    private var timer: Timer?
    private var clockOwnsTempo = false
    private var lastClockLog = 0.0
    private var logURL: URL?
    private var hudState = 0                 // 0 = status line only (launch), 1 = Control HUD + line, 2 = nothing
    private var syphonItem: NSMenuItem?
    private var syphonFrameCost: String = ""

    // MARK: setup

    func attach(app: AppDelegate) {
        self.app = app
        guard let r = app.renderer, let view = app.view else { return }
        let args = CommandLine.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        logURL = arg("--midi-log").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        if let u = logURL { try? "".write(to: u, atomically: true, encoding: .utf8) }

        let out = FrameOutput(device: r.device)
        output = out
        r.frameOutput = out

        let mapURL = arg("--midi-map").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? MidiControl.defaultMappingURL
        midi = MidiControl(mappingURL: mapURL)
        midi.log = { [weak self] s in self?.log(s) }
        midi.onAction = { [weak self] a, t in self?.perform(a, t) }
        midi.onControl = { [weak self] c, _ in self?.learnPanel?.controlMoved(c) }
        if let t = arg("--midi-learn").flatMap(MidiControl.Action.init(rawValue:)) { midi.learnTarget = t; log("midi: learn armed for \(t.rawValue)") }
        if !args.contains("--no-midi") { midi.start() }

        for v in [hudView, cheatView] {
            v.isHidden = true
            v.autoresizingMask = [.minXMargin, .minYMargin]
            app.window.contentView?.addSubview(v, positioned: .above, relativeTo: nil)
        }
        cheatView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        cheatView.setColumns(Self.cheatSheet, fontSize: 13)
        layoutOverlays()
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: app.window.contentView, queue: .main) { [weak self] _ in self?.layoutOverlays() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged(NSScreen.screens)
        }

        for (i, s) in NSScreen.screens.enumerated() {
            let px = s.convertRectToBacking(s.frame).size
            log("screen \(i): \(s.localizedName) \(Int(px.width))x\(Int(px.height)) max \(s.maximumFramesPerSecond) Hz" + (s == app.window.screen ? " (main window)" : ""))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        if args.contains("--syphon") { setSyphon(true) }
        if args.contains("--hud") { setHUD(1) }
        if let n = arg("--output-screen").flatMap(Int.init) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sendToScreen(n) } }
        if let script = arg("--vjscript") { runScript(script, snapDir: r.snapDir) }
        _ = view
    }

    func shutdown() {
        if let o = outputWindow, let out = output { o.close(output: out) }
        output?.syphon?.stop()
    }

    private func log(_ s: String) {
        NSLog("RAVE LIVE %@", s)
        renderer?.metrics.event(s, at: CACurrentMediaTime())
        guard let u = logURL else { return }
        let line = String(format: "%.3f %@\n", CACurrentMediaTime(), s)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    }

    // MARK: menus

    func addMenus(to main: NSMenu) {
        let outItem = NSMenuItem(); main.addItem(outItem)
        let om = NSMenu(title: "Output")
        let sy = NSMenuItem(title: "Syphon Server \"RAVE LIVE\"", action: #selector(menuSyphon(_:)), keyEquivalent: "")
        sy.target = self
        syphonItem = sy
        om.addItem(sy)
        let send = NSMenuItem(title: "Send to Display", action: nil, keyEquivalent: "")
        let sm = NSMenu(title: "Send to Display"); sm.delegate = self
        send.submenu = sm
        om.addItem(send)
        let stop = NSMenuItem(title: "Stop Output Display", action: #selector(menuStopOutput(_:)), keyEquivalent: "")
        stop.target = self; om.addItem(stop)
        om.addItem(.separator())
        let hud = NSMenuItem(title: "Control HUD", action: #selector(menuHUD(_:)), keyEquivalent: ""); hud.target = self; om.addItem(hud)
        let cs = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(menuCheat(_:)), keyEquivalent: ""); cs.target = self; om.addItem(cs)
        outItem.submenu = om

        let ctlItem = NSMenuItem(); main.addItem(ctlItem)
        let cm = NSMenu(title: "Controls")
        let learn = NSMenuItem(title: "MIDI Learn…", action: #selector(menuLearn(_:)), keyEquivalent: "l"); learn.target = self; cm.addItem(learn)
        let clk = NSMenuItem(title: "Sync to MIDI Clock", action: #selector(menuClock(_:)), keyEquivalent: ""); clk.target = self; cm.addItem(clk)
        cm.addItem(.separator())
        let imp = NSMenuItem(title: "Import MIDI Mappings…", action: #selector(menuImport(_:)), keyEquivalent: ""); imp.target = self; cm.addItem(imp)
        let exp = NSMenuItem(title: "Export MIDI Mappings…", action: #selector(menuExport(_:)), keyEquivalent: ""); exp.target = self; cm.addItem(exp)
        cm.addItem(.separator())
        let bm = NSMenu(title: "Master Brightness")
        for p in [100, 75, 50, 25, 0] {
            let it = NSMenuItem(title: "\(p)%", action: #selector(menuBrightness(_:)), keyEquivalent: ""); it.tag = p; it.target = self; bm.addItem(it)
        }
        let bi = NSMenuItem(title: "Master Brightness", action: nil, keyEquivalent: ""); bi.submenu = bm; cm.addItem(bi)
        ctlItem.submenu = cm
    }

    func menuNeedsUpdate(_ menu: NSMenu) {        // Send to Display: one entry per connected screen
        menu.removeAllItems()
        for (i, s) in NSScreen.screens.enumerated() {
            let px = s.convertRectToBacking(s.frame).size
            let it = NSMenuItem(title: "\(s.localizedName) — \(Int(px.width))×\(Int(px.height)), \(s.maximumFramesPerSecond) Hz" + (s == app?.window.screen ? " (this window)" : ""),
                                action: #selector(menuSend(_:)), keyEquivalent: "")
            it.tag = i; it.target = self
            it.state = outputWindow?.displayID == OutputWindow.displayID(s) ? .on : .off
            menu.addItem(it)
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuSyphon(_:)):
            item.state = output?.syphon != nil ? .on : .off
            item.toolTip = SyphonPublisher.available ? "Publish the visual to Resolume, VDMX, OBS, MadMapper…" : SyphonPublisher.loadError
            return SyphonPublisher.available
        case #selector(menuStopOutput(_:)): return outputWindow != nil
        case #selector(menuClock(_:)): item.state = midi.clockSync ? .on : .off; return true
        case #selector(menuHUD(_:)): item.state = hudView.isHidden ? .off : .on; return true
        case #selector(menuCheat(_:)): item.state = cheatView.isHidden ? .off : .on; return true
        case #selector(menuBrightness(_:)): item.state = Int(((output?.brightness ?? 1) * 100).rounded()) == item.tag ? .on : .off; return true
        default: return true
        }
    }

    @objc func menuSyphon(_ i: NSMenuItem) { setSyphon(output?.syphon == nil) }
    @objc func menuSend(_ i: NSMenuItem) { sendToScreen(i.tag) }
    @objc func menuStopOutput(_ i: NSMenuItem) { stopOutput(reason: "stopped") }
    @objc func menuHUD(_ i: NSMenuItem) { setHUD(hudView.isHidden ? 1 : 2) }
    @objc func menuCheat(_ i: NSMenuItem) { cheatView.isHidden.toggle() }
    @objc func menuLearn(_ i: NSMenuItem) { openLearnPanel() }
    @objc func menuClock(_ i: NSMenuItem) { midi.clockSync.toggle() }
    @objc func menuBrightness(_ i: NSMenuItem) { output?.brightness = Float(i.tag) / 100 }
    @objc func menuImport(_ i: NSMenuItem) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try midi.importMappings(from: u); learnPanel?.reload() } catch { alert("Couldn't import MIDI mappings", error.localizedDescription) }
    }
    @objc func menuExport(_ i: NSMenuItem) {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = "RAVE LIVE MIDI mappings.json"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try midi.exportMappings(to: u) } catch { alert("Couldn't export MIDI mappings", error.localizedDescription) }
    }
    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    // MARK: Syphon + output display

    func setSyphon(_ on: Bool) {
        guard let out = output, let r = renderer else { return }
        if on {
            guard out.syphon == nil else { return }
            if let s = SyphonPublisher(device: r.device) { out.syphon = s; log("syphon: server \"RAVE LIVE\" started") }
            else { log("syphon: unavailable — \(SyphonPublisher.loadError ?? "server init failed")") }
        } else {
            out.syphon?.stop(); out.syphon = nil; log("syphon: stopped")
        }
    }

    func sendToScreen(_ index: Int) {
        guard let app, let r = renderer, let out = output, index >= 0, index < NSScreen.screens.count else { log("output: no screen \(index)"); return }
        let s = NSScreen.screens[index]
        if let o = outputWindow { o.close(output: out); outputWindow = nil }
        let same = s == app.window.screen
        guard let o = OutputWindow(screen: s, renderer: r, mainView: app.view, sameScreenAsControls: same) else { return }
        outputWindow = o
        o.show(output: out)
        log("output: \(s.localizedName) \(Int(o.view.drawableSize.width))x\(Int(o.view.drawableSize.height)) @ \(o.targetFPS) fps (screen max \(s.maximumFramesPerSecond) Hz)" + (same ? ", same screen as the controls" : ""))
        app.window.makeKeyAndOrderFront(nil)
    }

    func stopOutput(reason: String) {
        guard let o = outputWindow, let out = output else { return }
        o.close(output: out)
        outputWindow = nil
        log("output: closed (\(reason)); main window renders again")
        app?.screenChanged(Notification(name: NSWindow.didChangeScreenNotification))
    }

    /// Screen plugged/unplugged. If the output display is gone, fall back to the main window.
    func screensChanged(_ screens: [NSScreen]) {
        guard let o = outputWindow else { return }
        if let s = screens.first(where: { OutputWindow.displayID($0) == o.displayID }) { o.screenChanged(s); return }
        stopOutput(reason: "\(o.screenName) disconnected")
        app?.status.stringValue = "Output display \(o.screenName) was disconnected. The visual is back in this window."
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.app?.status.stringValue.hasPrefix("Output display") == true { self?.app?.status.stringValue = "" }
        }
    }

    // MARK: actions (MIDI + keys share these)

    func perform(_ a: MidiControl.Action, _ t: MidiTrigger) {
        guard let app, let r = renderer else { return }
        let press = t.pressed
        switch a {
        case .modeNext where press: app.setMode(Renderer.Mode(rawValue: (r.mode.rawValue + 1) % Renderer.Mode.allCases.count)!)
        case .modePrev where press: app.setMode(Renderer.Mode(rawValue: (r.mode.rawValue + Renderer.Mode.allCases.count - 1) % Renderer.Mode.allCases.count)!)
        case .presetNext where press, .presetPrev where press:
            let dir = a == .presetNext ? 1 : -1
            if r.mode == .milkdrop, let m = r.milk { m.step(dir); m.director.manualSwitch(now: CACurrentMediaTime()) }
            else if let v = r.visuals { v.preset = (v.preset + VisualsRenderer.count + dir) % VisualsRenderer.count; v.autoCycle = false }
        case .intensity:
            if t.continuous { r.intensity = Renderer.Intensity(rawValue: min(2, Int(t.value * 3)))! }
            else if press { r.intensity = Renderer.Intensity(rawValue: (r.intensity.rawValue + 1) % 3)! }
        case .brightness:
            if t.continuous { output?.brightness = t.value } else if press { output?.brightness = (output?.brightness ?? 1) > 0.5 ? 0 : 1 }
        case .strobe:
            if t.continuous { r.manualStrobe = t.value >= 0.5 } else if press { r.manualStrobe = true } else if t.released { r.manualStrobe = false }
        case .blackout where press: r.blackout.toggle()
        case .tapTempo where press: _ = app.audio.tempo?.tap(at: CACurrentMediaTime())
        case .nudgeEarlier where press: r.userOffset -= 0.01
        case .nudgeLater where press: r.userOffset += 0.01
        case .bpmUp where press: app.audio.tempo?.nudge += 0.1
        case .bpmDown where press: app.audio.tempo?.nudge -= 0.1
        case .autoCycle where press:
            if r.mode == .milkdrop, let m = r.milk { m.director.locked.toggle() } else { r.visuals?.autoCycle.toggle() }
        default: return
        }
        if t.continuous && !t.pressed && !t.released && logURL == nil { return }   // a turning knob would flood the metrics events
        let v = r.mode == .milkdrop ? "MilkDrop " + (r.milk?.currentName ?? "-") : r.visuals.map { VisualsRenderer.presetNames[$0.preset % VisualsRenderer.count] } ?? "-"
        log(String(format: "midi: %@ value %.2f%@ -> mode %@ · preset %@ · intensity %@ · brightness %.2f · blackout %@ · strobe %@",
                   a.rawValue, t.value, t.pressed ? " press" : (t.released ? " release" : ""), r.mode.title, v, r.intensity.title,
                   output?.brightness ?? 1, r.blackout ? "on" : "off", r.manualStrobe ? "held" : "off"))
    }

    /// Keys this rig owns. Returns true when the key was consumed.
    func handleKey(_ e: NSEvent) -> Bool {
        let chars = e.characters ?? ""
        if chars == "?" || (e.charactersIgnoringModifiers == "/" && e.modifierFlags.contains(.shift)) { cheatView.isHidden.toggle(); return true }
        if e.keyCode == 53 && !cheatView.isHidden { cheatView.isHidden = true; return true }
        if chars.lowercased() == "h" && !e.modifierFlags.contains(.command) { setHUD(hudState == 1 ? 2 : 1); return true }
        return false
    }

    private func setHUD(_ state: Int) {
        guard let app, let r = renderer else { return }
        hudState = state
        hudView.isHidden = state != 1
        r.hudVisible = state != 2
        app.hud.isHidden = state == 2
        updateHUD()
    }

    // MARK: periodic: MIDI clock -> tempo, HUD text

    private func tick() {
        guard let app else { return }
        if let tempo = app.audio.tempo {
            if midi.clockSync, let b = midi.clockBPM() {
                tempo.manualBPM = (b * 100).rounded() / 100
                clockOwnsTempo = true
                let now = CACurrentMediaTime()
                if now - lastClockLog > 1 {
                    lastClockLog = now
                    log(String(format: "midi: clock %.2f BPM -> tempo source (app BPM %.2f)", b, app.audio.snapshot().bpm))
                }
            } else if clockOwnsTempo {
                tempo.manualBPM = nil
                clockOwnsTempo = false
                log("midi: clock stopped -> audio tempo tracker")
            }
        }
        if !hudView.isHidden && Int(CACurrentMediaTime() * 10) % 3 == 0 { updateHUD() }
    }

    private func updateHUD() {
        guard let app, let r = renderer, !hudView.isHidden else { return }
        let s = app.audio.snapshot()
        let preset = VisualsRenderer.presetNames[(r.visuals?.preset ?? 0) % VisualsRenderer.count] + ((r.visuals?.autoCycle ?? false) ? " (auto)" : "")
        let modeLine: String
        switch r.mode {
        case .show: modeLine = "SHOW → " + r.showScene.title
        default: modeLine = r.mode.title
        }
        let presetLine: String
        switch r.mode == .show ? r.showScene : r.mode {
        case .visuals: presetLine = preset
        case .aurora: presetLine = "AURORA symmetry \(r.aurora?.symmetry ?? 0)" + (r.camera?.running == true ? " · camera" : "")
        case .stage: presetLine = "Stage look \(Int(r.stage) + 1)"
        case .milkdrop:
            let m = r.milk
            presetLine = m?.ready == true ? (m?.currentName ?? "-") + (m?.director.locked == true ? " (locked)" : "") : (m?.lib == nil ? "MilkDrop engine missing" : "no MilkDrop presets")
        default: presetLine = "-"
        }
        let locked = s.bpm > 0 && s.confidence > 0.25
        let bpmSrc = clockOwnsTempo ? "MIDI CLOCK" : (app.audio.tempo?.manualBPM != nil ? "TAP" : (locked ? "LOCKED" : "searching"))
        let syphon = output?.syphon.map { $0.hasClients ? "on · client connected" : "on · no clients" } ?? (SyphonPublisher.available ? "off" : "not bundled")
        let midiLine = midi.started ? "\(midi.sourceNames.count) source\(midi.sourceNames.count == 1 ? "" : "s") · \(midi.mappings.mappings.count) mapped" + (midi.clockBPM().map { String(format: " · clock %.1f", $0) } ?? "") : "off"
        let outLine = outputWindow.map { "\($0.screenName) @ \($0.targetFPS) fps" } ?? "this window"
        var flags: [String] = []
        if r.blackout { flags.append("BLACKOUT") }
        if (output?.brightness ?? 1) < 0.999 { flags.append(String(format: "brightness %.0f%%", (output?.brightness ?? 1) * 100)) }
        if !r.strobeEnabled { flags.append("strobe off") } else if r.strobeOverride { flags.append("⚠️ STROBE LIMIT OFF") }
        let rows: [(String, String)] = [
            ("Mode", modeLine), ("Preset", presetLine),
            ("BPM", String(format: "%.1f  %@  · beat %d/4", s.bpm, bpmSrc, Int(r.beatClockIndex) % 4 + 1)),
            ("Intensity", r.intensity.title + (flags.isEmpty ? "" : "  · " + flags.joined(separator: " · "))),
            ("Audio", (CommandLine.arguments.contains("--demo") ? "demo (synthetic)" : s.source) + " · " + (s.playing ? "LIVE" : "quiet")),
            ("Syphon", syphon), ("MIDI", midiLine), ("Output", outLine),
        ]
        let text = "RAVE LIVE · CONTROL  (H hides, ? shortcuts)\n" + rows.map { $0.0.padding(toLength: 10, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
        hudView.setText(text, fontSize: 12)
        layoutOverlays()
    }

    private func layoutOverlays() {
        guard let cv = app?.window.contentView else { return }
        let b = cv.bounds
        let hs = hudView.fittingSize
        hudView.frame = NSRect(x: b.maxX - hs.width - 12, y: b.maxY - hs.height - 12, width: hs.width, height: hs.height)
        let cs = cheatView.fittingSize
        cheatView.frame = NSRect(x: (b.width - cs.width) / 2, y: (b.height - cs.height) / 2, width: cs.width, height: cs.height)
    }

    /// Two columns; plain key names so the monospaced columns line up (⌘/⇧/arrow glyphs are wider than a cell).
    static let cheatSheet = [
        """
        RAVE LIVE · KEYBOARD SHORTCUTS

        MODES & PRESETS
        V           next mode
        Cmd 1-5     SHOW / Stage / Classic /
                    AURORA / MILKDROP
        ]  [        next / previous preset
        1 - 8       preset (Classic) or Stage look
        A           auto-cycle presets on/off
        C, Cmd K    camera hands & body (AURORA)
        Shift T     Tweak panel (Classic)
        Cmd S, O    save / open a .ravelook

        VIEW & OUTPUT
        F, Cmd F    fullscreen      Esc  exit
        H           Control HUD (never on Syphon/output)
        ?           this sheet (? or Esc closes)
        Cmd L       MIDI Learn…
        Output menu Syphon, Send to Display
        """,
        """


        SHOW CONTROL
        I           intensity Chill/Normal/Wild
        B           blackout
        S           strobe on/off
        Shift S     lift the 3 flashes/s limit
        T           tap tempo
        Left/Right  BPM -/+ 0.1 (Shift: 1)
        ,  .        beat nudge -/+ 10 ms
        M           system audio <-> input

        MILKDROP
        P, Cmd P    preset browser (any mode)
        ]  [  R     next / previous / random
        L           lock preset (no auto changes)
        Shift F     favourite
        1-5, 0      rate / clear rating
        """,
    ]

    // MARK: MIDI learn panel

    func openLearnPanel() {
        if learnPanel == nil { learnPanel = MidiLearnPanel(midi: midi) }
        learnPanel?.reload()
        learnPanel?.window.makeKeyAndOrderFront(nil)
    }

    // MARK: scripted UI for tests: --vjscript "2:hud,3:shot=hud,4:cheat,5:learn,6:learnshot=learn,8:output=1,12:unplug"

    private func runScript(_ script: String, snapDir: URL) {
        for item in script.split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]) else { continue }
            let cmd = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in self?.scriptStep(cmd, snapDir: snapDir) }
        }
    }

    private func scriptStep(_ cmd: String, snapDir: URL) {
        let kv = cmd.split(separator: "=", maxSplits: 1).map(String.init)
        let val = kv.count > 1 ? kv[1] : ""
        log("script: \(cmd)")
        switch kv[0] {
        case "hud": setHUD(1)
        case "nohud": setHUD(2)
        case "cheat": cheatView.isHidden = false
        case "nocheat": cheatView.isHidden = true
        case "learn": openLearnPanel()
        case "nolearn": learnPanel?.window.orderOut(nil)
        case "syphon": setSyphon(true)
        case "nosyphon": setSyphon(false)
        case "output": sendToScreen(Int(val) ?? 0)
        case "stopoutput": stopOutput(reason: "script")
        case "unplug":      // simulate the output screen disappearing
            if let o = outputWindow { screensChanged(NSScreen.screens.filter { OutputWindow.displayID($0) != o.displayID }) }
        case "brightness": output?.brightness = Float(val) ?? 1
        case "shot": captureWindow(name: val, dir: snapDir)
        case "outshot": output?.onCapture = { img in Self.writePNG(img, to: snapDir.appendingPathComponent(val + ".png")) }
        case "learnshot":
            if let w = learnPanel?.window, let v = w.contentView { Self.writePNG(Self.render(view: v, background: w.backgroundColor), to: snapDir.appendingPathComponent(val + ".png")) }
        default: log("script: unknown \(cmd)")
        }
    }

    /// Main window as the performer sees it: the latest frame plus the AppKit overlays drawn on top.
    private func captureWindow(name: String, dir: URL) {
        guard let out = output else { return }
        out.onCapture = { [weak self] frame in
            guard let self, let cv = self.app?.window.contentView, let view = self.app?.view else { return }
            let scale = self.app?.window.backingScaleFactor ?? 2
            let w = Int(cv.bounds.width * scale), h = Int(cv.bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.scaleBy(x: scale, y: scale)
            var r = view.frame
            if self.outputWindow != nil {         // preview layer letterboxes the output (contentsGravity .resizeAspect)
                let fa = CGFloat(frame.width) / CGFloat(frame.height), va = r.width / r.height
                if fa > va { let h = r.width / fa; r = CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h) }
                else { let w = r.height * fa; r = CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height) }
                ctx.setFillColor(NSColor.black.cgColor); ctx.fill(view.frame)
            }
            ctx.draw(frame, in: r)
            for sub in cv.subviews where sub !== view && !sub.isHidden {
                ctx.draw(Self.render(view: sub), in: sub.frame)
            }
            if let img = ctx.makeImage() { Self.writePNG(img, to: dir.appendingPathComponent(name + ".png")) }
        }
    }

    static func render(view v: NSView, background: NSColor? = nil) -> CGImage {
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let bg = background, let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return rep.cgImage! }
        var fill = NSColor.black.cgColor
        v.effectiveAppearance.performAsCurrentDrawingAppearance { fill = bg.usingColorSpace(.deviceRGB)?.cgColor ?? fill }
        let r = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        ctx.setFillColor(fill); ctx.fill(r)            // panels are transparent in the cache; give them the window colour
        ctx.draw(rep.cgImage!, in: r)
        return ctx.makeImage() ?? rep.cgImage!
    }

    static func writePNG(_ img: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Rounded translucent text box (Control HUD, cheat sheet), one or more monospaced columns.
final class OverlayPanel: NSView {
    private let stack = NSStackView()
    init(alpha: CGFloat = 0.62) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: alpha).cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.borderWidth = 1
        stack.orientation = .horizontal; stack.alignment = .top; stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setText(_ s: String, fontSize: CGFloat) { setColumns([s], fontSize: fontSize) }
    func setColumns(_ cols: [String], fontSize: CGFloat) {
        while stack.arrangedSubviews.count < cols.count {
            let l = NSTextField(labelWithString: "")
            l.textColor = NSColor(white: 1, alpha: 0.92)
            stack.addArrangedSubview(l)
        }
        for (i, v) in stack.arrangedSubviews.enumerated() {
            guard let l = v as? NSTextField else { continue }
            l.font = .monospacedSystemFont(ofSize: fontSize, weight: .medium)
            l.stringValue = i < cols.count ? cols[i] : ""
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go through to the visual
}

/// "Controls > MIDI Learn…": move a knob or press a pad, then click the target it should drive.
final class MidiLearnPanel: NSObject {
    let window: NSPanel
    private let midi: MidiControl
    private let lastLabel = NSTextField(labelWithString: "Move a knob or press a pad on your controller…")
    private let sources = NSTextField(wrappingLabelWithString: "")
    private var rows: [(MidiControl.Action, NSButton, NSTextField)] = []
    private let clockBox = NSButton(checkboxWithTitle: "Sync tempo to MIDI clock (24 ppqn) when a clock is running", target: nil, action: nil)

    init(midi: MidiControl) {
        self.midi = midi
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "MIDI Learn"
        window.isReleasedWhenClosed = false
        super.init()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let head = NSTextField(wrappingLabelWithString: "1. Move a knob, fader or pad on your controller.\n2. Click the target it should control. Click ✕ to unmap.")
        head.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(head)
        lastLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        lastLabel.textColor = .systemOrange
        stack.addArrangedSubview(lastLabel)
        for a in MidiControl.Action.allCases {
            let b = NSButton(title: a.title, target: self, action: #selector(targetClicked(_:)))
            b.bezelStyle = .rounded; b.tag = rows.count
            b.widthAnchor.constraint(equalToConstant: 330).isActive = true
            b.alignment = .left
            let m = NSTextField(labelWithString: "")
            m.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            m.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let x = NSButton(title: "✕", target: self, action: #selector(clearClicked(_:)))
            x.bezelStyle = .inline; x.tag = rows.count
            let row = NSStackView(views: [b, m, x]); row.spacing = 8
            stack.addArrangedSubview(row)
            rows.append((a, b, m))
        }
        clockBox.target = self; clockBox.action = #selector(clockToggled(_:))
        stack.addArrangedSubview(clockBox)
        sources.font = .systemFont(ofSize: 11); sources.textColor = .secondaryLabelColor
        stack.addArrangedSubview(sources)
        let file = NSTextField(wrappingLabelWithString: "Saved to \(midi.mappingURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Import/Export in the Controls menu.")
        file.font = .systemFont(ofSize: 11); file.textColor = .secondaryLabelColor
        file.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(file)
        window.contentView = stack
        window.center()
    }

    func reload() {
        for (a, b, m) in rows {
            m.stringValue = midi.learnTarget == a ? "waiting…" : (midi.mappings.control(for: a.rawValue).map { $0.description } ?? "—")
            b.state = midi.learnTarget == a ? .on : .off
        }
        clockBox.state = midi.clockSync ? .on : .off
        sources.stringValue = midi.started ? "MIDI inputs: " + (midi.sourceNames.isEmpty ? "none connected" : midi.sourceNames.joined(separator: ", ")) : "MIDI is off"
        if let c = midi.lastControl { lastLabel.stringValue = "Last control: \(c)" }
    }

    func controlMoved(_ c: MidiControlID) {
        lastLabel.stringValue = "Last control: \(c)  → click a target"
        reload()
    }

    @objc private func targetClicked(_ b: NSButton) {
        let a = rows[b.tag].0
        if let c = midi.lastControl, midi.learnTarget == nil {
            midi.bindNow(c, to: a)
        } else {
            midi.learnTarget = a          // nothing moved yet: the next control that moves is bound
        }
        reload()
    }
    @objc private func clearClicked(_ b: NSButton) { midi.unbind(rows[b.tag].0); reload() }
    @objc private func clockToggled(_ b: NSButton) { midi.clockSync = b.state == .on }
}
