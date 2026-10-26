// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import MetalKit
import RaveAudio

/// Key handling lives on the view so it works fullscreen too.
final class StageView: MTKView {
    var onKey: ((NSEvent) -> Void)?
    var onMouse: ((NSPoint, NSPoint, Bool, Bool) -> Void)?   // location (0..1, top-left), delta, down, click
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    private func norm(_ e: NSEvent) -> NSPoint {
        let p = convert(e.locationInWindow, from: nil)
        return NSPoint(x: p.x / max(1, bounds.width), y: 1 - p.y / max(1, bounds.height))
    }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); onMouse?(norm(e), .zero, true, true) }
    override func mouseDragged(with e: NSEvent) { onMouse?(norm(e), NSPoint(x: e.deltaX / max(1, bounds.width), y: e.deltaY / max(1, bounds.height)), true, false) }
    override func mouseMoved(with e: NSEvent) { onMouse?(norm(e), NSPoint(x: e.deltaX / max(1, bounds.width), y: e.deltaY / max(1, bounds.height)), false, false) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}

nonisolated(unsafe) var r_displayInfo = ""

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: StageView!
    var renderer: Renderer!
    let audio = AudioEngine()
    let vj = VJRig()
    let hud = NSTextField(labelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    lazy var metricsURL: URL = {
        let a = CommandLine.arguments
        let path = a.firstIndex(of: "--metrics").flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil } ?? "~/.cache/ravelive/metrics.json"
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }()
    var dumpTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        let w = Double(arg("--width") ?? "1920") ?? 1920, h = Double(arg("--height") ?? "1080") ?? 1080

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w / 2, height: h / 2),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RAVE LIVE"
        window.collectionBehavior = [.fullScreenPrimary]
        view = StageView(frame: window.contentView!.bounds, device: MTLCreateSystemDefaultDevice())
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2   // less queueing = lower audio->photon latency
        // Pick the smallest whole divisor of the display refresh that is >= 60 fps
        // (144 Hz -> 72, 120 -> 60, 60 -> 60). Asking for exactly 60 on a 144 Hz panel gives 48.
        let maxHz = (NSScreen.main?.maximumFramesPerSecond ?? 60)
        view.preferredFramesPerSecond = Int(arg("--fps") ?? "") ?? Self.targetFPS(maxHz)
        NSLog("RAVE LIVE: display max %d Hz, rendering at %d fps", maxHz, view.preferredFramesPerSecond)
        r_displayInfo = "\(NSScreen.main?.localizedName ?? "?") max \(maxHz) Hz, target \(view.preferredFramesPerSecond) fps"
        view.drawableSize = CGSize(width: w, height: h)
        view.autoResizeDrawable = arg("--width") == nil
        QualityController.shared.setUp(view: view, override: arg("--quality"))
        guard let r = Renderer(view: view, audio: audio) else {
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = "RAVE LIVE can't start the GPU renderer"
            a.informativeText = "This app needs a Mac with Metal support (macOS 12 or later). Metal could not be initialised on this machine."
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        renderer = r
        view.delegate = r
        QualityController.shared.attach(r)
        r.forcedLook = arg("--look").flatMap(Float.init); r.forcedBeam = arg("--beam").flatMap(Float.init); r.forcedLaser = arg("--laser").flatMap(Float.init)
        if args.contains("--visuals") { r.mode = .visuals }
        if args.contains("--stage") { r.mode = .stage }
        if args.contains("--aurora") { r.mode = .aurora }
        if args.contains("--show") { r.mode = .show }
        if let sd = arg("--snapdir") { r.snapDir = URL(fileURLWithPath: NSString(string: sd).expandingTildeInPath) }
        r.fakeMouseFrom = arg("--fakemouse-from").flatMap(Double.init) ?? -1
        r.fakeHandsFrom = arg("--fakehands-from").flatMap(Double.init) ?? 0
        r.fakeHands = args.contains("--fakehands") || arg("--fakehands-from") != nil
        if let iv = arg("--intensity").flatMap(Int.init), let it = Renderer.Intensity(rawValue: iv) { r.intensity = it }
        if let tr = arg("--trim").flatMap(Double.init) { r.userOffset = tr / 1000 }
        if let pr = arg("--preset").flatMap(Int.init) { r.visuals?.preset = pr; r.visuals?.autoCycle = false }
        if let s = arg("--snap") { r.snapTimes = s.split(separator: ",").compactMap { Double($0) }.sorted() }
        r.lumLogPath = arg("--lumlog").map { NSString(string: $0).expandingTildeInPath }
        window.contentView!.addSubview(view)

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        hud.textColor = NSColor(white: 1, alpha: 0.75)
        hud.frame = NSRect(x: 12, y: 8, width: 1200, height: 18)
        hud.autoresizingMask = [.maxYMargin]
        window.contentView!.addSubview(hud)
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.textColor = .white
        status.frame = NSRect(x: 40, y: 80, width: 700, height: 200)
        status.autoresizingMask = [.maxYMargin, .maxXMargin]
        window.contentView!.addSubview(status)
        r.onHUD = { [weak self] s in DispatchQueue.main.async { self?.hud.stringValue = s } }
        audio.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status.stringValue = s } }
        view.onKey = { [weak self] e in self?.key(e) }
        view.onMouse = { [weak self] p, d, down, click in
            guard let r = self?.renderer else { return }
            let pos = SIMD2<Float>(Float(p.x), Float(p.y)), vel = SIMD2<Float>(Float(d.x), Float(d.y)) * 3.0
            r.mousePointer = .init(pos: pos, vel: vel, down: down, burst: click)
            r.pointerEvent(pos: pos, down: down, click: click)
        }
        buildMenu()
        vj.attach(app: self)
        modeControl.segmentCount = Renderer.Mode.allCases.count
        for m in Renderer.Mode.allCases { modeControl.setLabel(m.title, forSegment: m.rawValue); modeControl.setWidth(110, forSegment: m.rawValue) }
        modeControl.target = self; modeControl.action = #selector(modeClicked(_:))
        modeControl.selectedSegment = r.mode.rawValue
        modeControl.frame = NSRect(x: 12, y: window.contentView!.bounds.height - 40, width: 456, height: 28)
        modeControl.autoresizingMask = [.minYMargin, .maxXMargin]
        window.contentView!.addSubview(modeControl)
        r.onModeChange = { [weak self] m in DispatchQueue.main.async { self?.modeControl.selectedSegment = m.rawValue } }

        window.center()
        if let si = arg("--screen").flatMap(Int.init), si < NSScreen.screens.count {
            let f = NSScreen.screens[si].visibleFrame
            window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.screenChanged(Notification(name: NSWindow.didChangeScreenNotification)) }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)), name: NSWindow.didChangeScreenNotification, object: window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        photosensitivityWarningIfNeeded(skip: args.contains("--accept-warning")) { [weak self] in
            guard let self else { return }
            self.audio.refereeEnabled = !args.contains("--no-referee")
            self.audio.startReferee()
            if args.contains("--demo") { self.audio.startDemo() }
            else { let src = AudioMenu.initialSource(args); Task { await self.audio.start(src) } }
        }
        dumpTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.renderer.outputLatency = OutputLatency.current()     // follows AirPods/speaker switches
            self.renderer.metrics.sync = self.renderer.syncInfo
            self.renderer.metrics.dump(to: self.metricsURL)
        }
        if let q = arg("--autoquit").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { [weak self] in
                guard let self else { return }
                self.renderer.metrics.dump(to: self.metricsURL); NSApp.terminate(nil)
            }
        }
        if args.contains("--fullscreen") { window.toggleFullScreen(nil) }
        // Test harness: inject real key events through the window's responder chain, e.g. --keys "v@3,v@6"
        if let ks = arg("--keys") {
            for item in ks.split(separator: ",") {
                let parts = item.split(separator: "@"); guard parts.count == 2, let at = Double(parts[1]) else { continue }
                let ch = String(parts[0])
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: self.window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                         isARepeat: false, keyCode: 0) else { return }
                    self.window.sendEvent(ev)
                }
            }
        }
    }

    /// Smallest whole divisor of the refresh rate that is >= 60 (144 Hz -> 72). Measured: asking for 60 on a
    /// 144 Hz panel gives 48, and 60 on the 120 Hz ProMotion panel gave ~49, so 120 Hz runs at native 120.
    static func targetFPS(_ maxHz: Int) -> Int {
        if maxHz == 120 { return 120 }
        var fps = maxHz
        for d in 1...8 where maxHz % d == 0 && maxHz / d >= 60 { fps = maxHz / d }
        return fps
    }

    @objc func screenChanged(_ n: Notification) {
        let maxHz = window.screen?.maximumFramesPerSecond ?? 60
        let fps = Self.targetFPS(maxHz)
        view.preferredFramesPerSecond = fps
        r_displayInfo = "\(window.screen?.localizedName ?? "?") max \(maxHz) Hz, target \(fps) fps"
    }

    let modeControl = NSSegmentedControl()

    @objc func modeClicked(_ c: NSSegmentedControl) {
        setMode(Renderer.Mode(rawValue: c.selectedSegment) ?? .stage)
        window.makeFirstResponder(view)   // keep keyboard shortcuts working after a click
    }
    @objc func menuMode(_ i: NSMenuItem) { setMode(Renderer.Mode(rawValue: i.tag) ?? .stage) }
    @objc func menuCamera(_ i: NSMenuItem) { toggleCamera() }
    @objc func menuFullscreen(_ i: NSMenuItem) { window.toggleFullScreen(nil) }

    func setMode(_ m: Renderer.Mode) {
        renderer.mode = m
        if m == .visuals { renderer.visuals?.autoCycle = true }
        modeControl.selectedSegment = m.rawValue
        renderer.metrics.event("mode->" + m.title, at: CACurrentMediaTime())
    }
    func toggleCamera() {
        guard let r = renderer else { return }
        if r.camera?.running == true { r.camera?.stop(); r.camera = nil; return }
        let h = HandTracker()
        h.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status.stringValue = s } }
        r.camera = h; h.start()
        if r.mode != .aurora && r.mode != .show { setMode(.aurora) }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit RAVE LIVE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let vm = NSMenu(title: "View")
        for m in Renderer.Mode.allCases {
            let it = NSMenuItem(title: m.title, action: #selector(menuMode(_:)), keyEquivalent: "\(m.rawValue + 1)")
            it.keyEquivalentModifierMask = [.command]; it.tag = m.rawValue; it.target = self; vm.addItem(it)
        }
        vm.addItem(.separator())
        let cam = NSMenuItem(title: "Camera Hands & Body (AURORA)", action: #selector(menuCamera(_:)), keyEquivalent: "k"); cam.target = self; vm.addItem(cam)
        let fs = NSMenuItem(title: "Fullscreen", action: #selector(menuFullscreen(_:)), keyEquivalent: "f"); fs.target = self; vm.addItem(fs)
        vm.addItem(QualityController.shared.menuItem())
        viewItem.submenu = vm
        main.addItem(AudioMenu.shared.menuItem(audio: audio))
        vj.addMenus(to: main)
        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { vj.shutdown(); renderer?.metrics.dump(to: metricsURL); audio.stopReferee() }

    private func photosensitivityWarningIfNeeded(skip: Bool, then: @escaping () -> Void) {
        let key = "acceptedPhotosensitivityWarning"
        if skip || UserDefaults.standard.bool(forKey: key) { then(); return }
        let a = NSAlert()
        a.messageText = "Photosensitivity warning"
        a.informativeText = "RAVE LIVE uses flashing lights and strobes that react to music. A small share of people can have seizures from flashing lights. Strobes are limited to 3 flashes per second by default.\n\nIf you or anyone watching has photosensitive epilepsy, don't use strobe effects (press S to turn them off)."
        a.addButton(withTitle: "I understand")
        a.addButton(withTitle: "Quit")
        if a.runModal() == .alertFirstButtonReturn { UserDefaults.standard.set(true, forKey: key); then() } else { NSApp.terminate(nil) }
    }

    private func key(_ e: NSEvent) {
        let r = renderer!
        if vj.handleKey(e) { return }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (ch, e.modifierFlags.contains(.shift)) {
        case ("s", true):
            if !r.strobeOverride {
                let a = NSAlert()
                a.messageText = "Lift the strobe limit?"
                a.informativeText = "This allows more than 3 flashes per second, which raises the risk for photosensitive viewers."
                a.addButton(withTitle: "Lift limit"); a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn { r.strobeOverride = true }
            } else { r.strobeOverride = false }
        case ("s", false): r.strobeEnabled.toggle()
        case ("b", _): r.blackout.toggle()
        case ("f", _): window.toggleFullScreen(nil)
        case ("h", _): r.hudVisible.toggle(); hud.isHidden = !r.hudVisible
        case ("m", _): AudioMenu.shared.toggle()
        case ("t", _): audio.tempo?.tap(at: CACurrentMediaTime())
        case ("i", _): r.intensity = Renderer.Intensity(rawValue: (r.intensity.rawValue + 1) % 3)!
        case (",", _): r.userOffset -= 0.01      // visuals earlier
        case (".", _): r.userOffset += 0.01      // visuals later
        case ("v", _): setMode(Renderer.Mode(rawValue: (r.mode.rawValue + 1) % Renderer.Mode.allCases.count)!)
        case ("c", _): toggleCamera()
        case ("a", _): r.visuals?.autoCycle.toggle()
        case ("]", _): if let v = r.visuals { v.preset = (v.preset + 1) % VisualsRenderer.count; v.autoCycle = false }
        case ("[", _): if let v = r.visuals { v.preset = (v.preset + VisualsRenderer.count - 1) % VisualsRenderer.count; v.autoCycle = false }
        case ("1", _), ("2", _), ("3", _), ("4", _), ("5", _), ("6", _), ("7", _), ("8", _):
            let n = Int(ch)! - 1
            if r.mode == .visuals { r.visuals?.preset = n; r.visuals?.autoCycle = false } else if n < 4 { r.stage = Float(n) }
        default:
            switch e.keyCode {
            case 123: audio.tempo?.nudge -= e.modifierFlags.contains(.shift) ? 1 : 0.1   // left
            case 124: audio.tempo?.nudge += e.modifierFlags.contains(.shift) ? 1 : 0.1   // right
            case 53: if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }  // esc
            default: break
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
