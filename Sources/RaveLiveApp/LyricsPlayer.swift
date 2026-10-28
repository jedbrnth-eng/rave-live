// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import QuartzCore

/// Synced lyrics overlay + Now Playing card. Both are AppKit views over the main window (like the HUD), so they never
/// reach Syphon or the output display. Follow-up: an option to burn lyrics into the output frame.
final class LyricsController: NSObject {
    enum LyricsState: Equatable { case off, waiting, looking, synced, remix, lengthDiffers, noLength, instrumental, notFound, offline
        /// Quiet one-liner for the card. nil = nothing to say.
        var note: String? {
            switch self {
            case .off, .waiting: return nil
            case .looking: return "finding lyrics…"
            case .synced: return "lyrics: lrclib.net"
            case .remix: return "lyrics off: remix/edit"
            case .lengthDiffers: return "lyrics off: other version"     // length is >3 s from the LRCLIB match
            case .noLength: return "lyrics off: no track length"
            case .instrumental: return "instrumental"
            case .notFound: return "no synced lyrics"
            case .offline: return "lyrics offline"
            }
        }
    }

    private weak var app: AppDelegate?
    let source: NowPlayingSource
    private let client = LRCLIBClient()
    private let cache = LyricsCache(dir: LyricsCache.defaultDir)
    let overlay = LyricsOverlayView()
    let card = PlayerCardView()
    private var timer: Timer?
    private(set) var info: NowPlayingInfo?
    private(set) var state: LyricsState = .off
    private var lines: [LyricLine] = []
    private var lookupKey = ""
    private var lookupTask: Task<Void, Never>?
    private var shownIndex: Int? = -1
    private var shownPair = ("\u{1}", "\u{1}")
    /// In a long instrumental gap the next line only appears this many seconds before it is sung.
    static let nextLineLead = 8.0
    private var lastWake = -100.0
    private var retryAt: Double?
    private var hudLevel: OverlayLevel = .status
    private var logURL: URL?

    // Live settings (Prefs, unless a command-line flag set them)
    private(set) var lyricsOn: Bool
    private(set) var cardOn: Bool
    private(set) var size: Int
    private(set) var offsetMs: Int

    init(app: AppDelegate) {
        self.app = app
        let a = CommandLine.arguments
        func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil } }
        let p = Prefs.shared
        lyricsOn = a.contains("--lyrics") ? true : (a.contains("--no-lyrics") ? false : p.lyricsEnabled)
        cardOn = a.contains("--player-card") ? true : (a.contains("--no-player-card") ? false : p.playerCard)
        size = arg("--lyrics-size").flatMap(Int.init).map { max(0, min(2, $0)) } ?? p.lyricsSize
        offsetMs = arg("--lyrics-offset").flatMap(Int.init).map { max(-1000, min(1000, $0)) } ?? p.lyricsOffsetMs
        logURL = arg("--lyrics-log").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        source = NowPlayingSource()
        super.init()
        if let u = logURL { try? "".write(to: u, atomically: true, encoding: .utf8) }
        source.log = { [weak self] s in DispatchQueue.main.async { self?.log(s) } }
        source.onChange = { [weak self] i in self?.nowPlayingChanged(i) }
        source.onStatus = { [weak self] _ in self?.app?.settings?.refresh() }
        guard let cv = app.window.contentView else { return }
        overlay.autoresizingMask = [.width, .maxYMargin]
        card.autoresizingMask = [.maxXMargin, .maxYMargin]
        cv.addSubview(overlay, positioned: .above, relativeTo: app.view)
        cv.addSubview(card, positioned: .above, relativeTo: overlay)
        card.prev.target = self; card.prev.action = #selector(cardPrev(_:))
        card.play.target = self; card.play.action = #selector(cardPlay(_:))
        card.next.target = self; card.next.action = #selector(cardNext(_:))
        card.onHover = { [weak self] in self?.wake() }
        card.isHidden = true; overlay.isHidden = true
        layout()
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: cv, queue: .main) { [weak self] _ in self?.layout() }
        log("lyrics: adapter \(source.adapter == nil ? "missing" : "found") · lyrics \(lyricsOn ? "on" : "off") · card \(cardOn ? "on" : "off") · offset \(offsetMs) ms · host \(client.host)")
        updateSource()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)                  // keeps lyrics moving while a menu is open or the window resizes
        timer = t
    }

    func shutdown() { timer?.invalidate(); lookupTask?.cancel(); source.stop() }

    func log(_ s: String) {
        NSLog("RAVE LIVE %@", s)
        app?.renderer?.metrics.event(s, at: CACurrentMediaTime())
        guard let u = logURL else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, s)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    }

    /// The adapter only runs while lyrics or the card are switched on.
    private func updateSource() {
        if lyricsOn || cardOn { source.start() } else { source.stop(); nowPlayingChanged(nil) }
    }

    // MARK: settings (Settings window, keys)

    var adapterNote: String {
        switch source.mainStatus {
        case .missing: return "The Now Playing reader isn't included in this build, so lyrics and the player card are off. Build it with scripts/build_mediaremote_adapter.sh, then scripts/make_app.sh."
        case .failed(let why): return "Now Playing is unavailable: \(why). Lyrics and the player card are off."
        case .off: return "Now Playing reader is off (lyrics and the player card are both switched off)."
        case .restarting: return "Now Playing reader restarting…"
        case .running:
            guard let i = info else { return "Now Playing: nothing is playing." }
            return "Now Playing: \(i.title) — \(NowPlayingSource.appName(i.bundleID))" + (state.note.map { " · \($0)" } ?? "")
        }
    }

    func setLyrics(_ on: Bool, save: Bool = true) {
        lyricsOn = on
        if save { Prefs.shared.lyricsEnabled = on }
        lookupKey = ""; lines = []; shownIndex = -1; shownPair = ("\u{1}", "\u{1}")
        if !on { lookupTask?.cancel(); lookupTask = nil }       // nothing more goes to lrclib.net once lyrics are off
        updateSource()
        refreshLyrics()
        log("lyrics: \(on ? "on" : "off")")
    }
    func setCard(_ on: Bool, save: Bool = true) {
        cardOn = on
        if save { Prefs.shared.playerCard = on }
        updateSource(); wake()
        log("lyrics: card \(on ? "on" : "off")")
    }
    func setSize(_ s: Int) { size = max(0, min(2, s)); Prefs.shared.lyricsSize = size; overlay.size = size; layout() }
    func setOffset(_ ms: Int) {
        offsetMs = max(-1000, min(1000, ms)); Prefs.shared.lyricsOffsetMs = offsetMs
        log("lyrics: offset \(offsetMs) ms")
    }
    func resetToDefaults() { setLyrics(false, save: false); setCard(true, save: false); size = 1; offsetMs = 0; overlay.size = 1; layout() }

    /// H key / Settings HUD level. Clean hides the card and the lyrics too.
    func overlayChanged(_ l: OverlayLevel) { hudLevel = l; tick() }

    func wake() { lastWake = CACurrentMediaTime() }

    // MARK: Now Playing -> lyrics

    private func nowPlayingChanged(_ i: NowPlayingInfo?) {
        let old = info
        info = i
        if old?.trackKey != i?.trackKey {
            if let i { log(String(format: "nowplaying: track \"%@\" — %@ (%@) %.1f s", i.title, i.artist, i.bundleID, i.duration ?? -1)) }
            else { log("nowplaying: nothing playing") }
            wake(); lines = []; shownIndex = -1; lookupKey = ""; shownPair = ("\u{1}", "\u{1}")
            lookupTask?.cancel(); lookupTask = nil
            refreshLyrics()
        } else if old?.playing != i?.playing {
            log("nowplaying: \(i?.playing == true ? "playing" : "paused") at \(String(format: "%.2f", i?.position(at: Date().timeIntervalSince1970) ?? 0)) s")
            wake()
        }
        card.update(i, app: i.map { NowPlayingSource.appName($0.bundleID) } ?? "")
        if old?.artwork != i?.artwork || old?.trackKey != i?.trackKey || card.art.image == nil { card.setArtwork(i?.artwork) }
    }

    private func setState(_ s: LyricsState) {
        guard s != state else { return }
        state = s
        log("lyrics: state \(s)" + (s.note.map { " (\($0))" } ?? ""))
        app?.settings?.refresh()
    }

    private func refreshLyrics() {
        guard lyricsOn, let i = info else { setState(.off); return }
        let key = LyricsCache.key(title: i.title, artist: i.artist, duration: i.duration)
        guard key != lookupKey else { return }
        lookupKey = key; retryAt = nil
        if TrackTitle.hasRemixMarker(i.title) { setState(.remix); return }          // remixes are never looked up
        guard let d = i.duration, d > 0 else { setState(.noLength); return }
        if let hit = cache.load(key) { log("lyrics: cache hit \(key)"); apply(hit, for: i); return }
        setState(.looking)
        log("lyrics: lookup \"\(TrackTitle.clean(i.title, strict: false))\" / \(TrackTitle.cleanArtist(i.artist)) / \(Int(d.rounded())) s")
        let t0 = CACurrentMediaTime()
        lookupTask?.cancel()
        lookupTask = Task { [client] in
            let l = await client.lookupDetailed(title: i.title, artist: i.artist, album: i.album, duration: d)
            await MainActor.run { [weak self] in
                guard let self, self.lookupKey == key, !Task.isCancelled else { return }
                let r = l.result
                self.log(String(format: "lyrics: lookup done in %.2f s -> %@%@", CACurrentMediaTime() - t0, Self.describe(r), l.cacheable ? "" : " (not cached)"))
                var gate: LyricsGate?
                if case .synced(let rec) = r { gate = LyricsGate.decide(rawTitle: i.title, trackDuration: i.duration, matchDuration: rec.duration) }
                if LyricsCache.shouldStore(r, cacheable: l.cacheable, gate: gate) { self.cache.store(r, key) }
                self.apply(r, for: i)
            }
        }
    }

    static func describe(_ r: LyricsResult) -> String {
        switch r {
        case .synced(let rec): return "synced id \(rec.id) (\(rec.duration.map { String(format: "%.1f s", $0) } ?? "no length"))"
        default: return "\(r)"
        }
    }

    private func apply(_ r: LyricsResult, for i: NowPlayingInfo) {
        switch r {
        case .synced(let rec):
            switch LyricsGate.decide(rawTitle: i.title, trackDuration: i.duration, matchDuration: rec.duration) {
            case .show:
                lines = LRC.parse(rec.syncedLyrics ?? ""); shownIndex = -1; shownPair = ("\u{1}", "\u{1}")
                setState(lines.isEmpty ? .notFound : .synced)
                log("lyrics: \(lines.count) synced lines, match \(String(format: "%.1f", rec.duration ?? 0)) s vs track \(String(format: "%.1f", i.duration ?? 0)) s")
            case .remix: setState(.remix)
            case .lengthDiffers: setState(.lengthDiffers)
            case .noLength: setState(.noLength)
            }
        case .instrumental: setState(.instrumental)
        case .plainOnly, .notFound: setState(.notFound)
        case .offline:
            setState(.offline)
            retryAt = CACurrentMediaTime() + 30                  // try again in 30 s if the same song is still on
        }
    }

    /// Song position the listener hears now: adapter position minus the audio output latency, minus the user trim.
    func heardPosition() -> Double? {
        guard let i = info else { return nil }
        let lat = app?.renderer?.outputLatency.seconds ?? 0
        return i.position(at: Date().timeIntervalSince1970) - lat - Double(offsetMs) / 1000
    }

    /// Test log line for snapshots: position, the line index and its LRC timestamp.
    func describeNow(_ tag: String) {
        let pos = info.map { $0.position(at: Date().timeIntervalSince1970) } ?? -1
        let heard = heardPosition() ?? -1
        let idx = LRC.index(at: heard, in: lines)
        // which LRC line the overlay's text actually is (first line with that text at or before `heard`)
        let shownText = overlay.currentText
        let shownIdx = overlay.isHidden ? nil : lines.indices.last { lines[$0].text == shownText && lines[$0].time <= heard + 0.5 }
        log(String(format: "lyrics: %@ pos=%.3f heard=%.3f latency=%.0fms offset=%dms state=%@ expectedLine=%@ expectedTime=%@ shownLine=%@ shownTime=%@ overlay=%@ card=%@",
                   tag, pos, heard, (app?.renderer?.outputLatency.seconds ?? 0) * 1000, offsetMs, "\(state)",
                   idx.map(String.init) ?? "none", idx.map { String(format: "%.2f", lines[$0].time) } ?? "-",
                   shownIdx.map(String.init) ?? "none", shownIdx.map { String(format: "%.2f", lines[$0].time) } ?? "-",
                   overlay.isHidden ? "hidden" : "visible", card.isHidden ? "hidden" : String(format: "visible(alpha %.2f)", card.alphaValue)))
    }

    // MARK: per frame (30 Hz)

    private func tick() {
        let now = CACurrentMediaTime()
        if let r = retryAt, now > r, state == .offline { lookupKey = ""; retryAt = nil; refreshLyrics() }
        let clean = hudLevel == .clean
        // card: visible for a few seconds after mouse movement / a track or play-state change
        let awake = now - lastWake < 4
        let wantCard = cardOn && info != nil && !clean && source.adapter != nil
        card.isHidden = !wantCard
        if wantCard {
            card.alphaValue += ((awake || card.hovering ? 1 : 0) - card.alphaValue) * 0.15
            card.setNote(lyricsOn ? state.note : nil)
            if let i = info { card.setProgress(position: i.position(at: Date().timeIntervalSince1970), duration: i.duration, playing: i.playing) }
        }
        // lyrics
        let wantLyrics = lyricsOn && state == .synced && info != nil && !clean
        overlay.isHidden = !wantLyrics
        guard wantLyrics, let heard = heardPosition() else { return }
        let idx = LRC.index(at: heard, in: lines)
        shownIndex = idx
        let cur = idx.map { lines[$0].text } ?? ""
        let nextIdx = (idx ?? -1) + 1
        var nextText = nextIdx < lines.count ? lines[nextIdx].text : ""
        if cur.isEmpty && nextIdx < lines.count && lines[nextIdx].time - heard > Self.nextLineLead { nextText = "" }
        if cur != shownPair.0 || nextText != shownPair.1 {
            shownPair = (cur, nextText)
            overlay.show(current: cur, next: nextText)
        }
        // gentle breath on the beat: cosine of the heard beat phase, peaking on the beat; nothing when the tempo is unlocked
        var breath = 0.0
        if let r = app?.renderer, r.beatLocked {
            let c = cos(2 * Double.pi * r.heardBeatPhase)
            breath = 0.5 + 0.5 * c
        }
        overlay.breathe(breath)
    }

    private func layout() {
        guard let cv = app?.window.contentView else { return }
        let b = cv.bounds
        card.frame = NSRect(x: 12, y: 32, width: card.frame.width, height: card.frame.height)
        overlay.size = size
        let bottom = max(card.frame.maxY + 10, b.height * 0.10)
        overlay.frame = NSRect(x: 0, y: bottom, width: b.width, height: overlay.preferredHeight(for: b))
        overlay.layoutLines()
    }

    // MARK: card buttons

    @objc private func cardPrev(_ b: NSButton) { log("card: previous"); source.send(.previous); wake() }
    @objc private func cardPlay(_ b: NSButton) { log("card: play/pause"); source.send(.toggle); wake() }
    @objc private func cardNext(_ b: NSButton) { log("card: next"); source.send(.next); wake() }
    func pressPlayPause() { card.play.performClick(nil) }
}

/// Current line large and centred low on screen, next line smaller and dimmer; lines crossfade.
/// Plain NSTextFields (not CATextLayers) so the `shot=` window snapshots capture exactly what is on screen.
final class LyricsOverlayView: NSView {
    private let cur = [NSTextField(wrappingLabelWithString: ""), NSTextField(wrappingLabelWithString: "")]
    private let next = NSTextField(wrappingLabelWithString: "")
    private var front = 0
    private var texts = ["", ""]
    private var nextText = ""
    private var breath: CGFloat = 0
    var size = 1
    private var scale: CGFloat { [0.042, 0.056, 0.074][max(0, min(2, size))] }
    private var big: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrim.alphaValue = 0
        scrim.autoresizingMask = [.width, .height]
        addSubview(scrim)
        for l in cur + [next] {
            l.alignment = .center
            l.maximumNumberOfLines = 2                      // long lines wrap onto a second line, then truncate
            l.lineBreakMode = .byWordWrapping
            l.cell?.truncatesLastVisibleLine = true
            l.drawsBackground = false
            l.isBordered = false
            l.alphaValue = 0
            l.isHidden = true
            addSubview(l)
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Soft dark halo behind the lines so they stay readable over bright visuals. A drawn subview (so window snapshots
    /// include it) that fades with the text, feathered to transparent so it reads as shade, not a box.
    private final class Scrim: NSView {
        var width: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let w = min(bounds.width * 0.9, max(width, bounds.width * 0.6))
            let r = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)   // inside bounds: no clipped edge
            NSGradient(colors: [NSColor(white: 0, alpha: 0.42), NSColor(white: 0, alpha: 0.18), NSColor(white: 0, alpha: 0)],
                       atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)?
                .draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
        }
    }
    private let scrim = Scrim()

    func preferredHeight(for b: NSRect) -> CGFloat { b.height * scale * 3.9 }

    private func attributed(_ s: String, size px: CGFloat, weight: NSFont.Weight, alpha: CGFloat, glow: CGFloat, glowAlpha: CGFloat) -> NSAttributedString {
        let sh = NSShadow()
        sh.shadowColor = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: glowAlpha)
        sh.shadowBlurRadius = glow
        sh.shadowOffset = .zero
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: px, weight: weight),
                                                          .foregroundColor: NSColor(white: 1, alpha: alpha), .shadow: sh, .paragraphStyle: p])
    }

    func layoutLines() {
        let w = bounds.width * 0.8, x = (bounds.width - w) / 2
        big = max(14, (window?.contentView?.bounds.height ?? bounds.height * 3) * scale)
        let small = big * 0.55
        next.frame = NSRect(x: x, y: 0, width: w, height: small * 1.5)
        for l in cur { l.frame = NSRect(x: x, y: small * 1.5, width: w, height: big * 2.5) }
        scrim.frame = bounds; scrim.width = big * 10; scrim.needsDisplay = true
        redraw()
    }

    private func redraw() {
        let b = breath
        for (i, l) in cur.enumerated() {
            l.attributedStringValue = attributed(texts[i], size: big * (1 + 0.025 * b), weight: .bold, alpha: 1, glow: 6 + 6 * b, glowAlpha: 0.5 + 0.2 * b)
        }
        next.attributedStringValue = attributed(nextText, size: big * 0.55, weight: .medium, alpha: 0.55, glow: 4, glowAlpha: 0.3)
    }

    /// Smooth crossfade (0.4 s) between the old and the new line. No motion besides the fade.
    func show(current: String, next n: String) {
        let old = cur[front]
        front = 1 - front
        let new = cur[front]
        texts[front] = current
        nextText = n
        redraw()
        new.isHidden = current.isEmpty
        next.isHidden = n.isEmpty
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            new.animator().alphaValue = current.isEmpty ? 0 : 1
            old.animator().alphaValue = 0
            next.animator().alphaValue = n.isEmpty ? 0 : 1
            scrim.animator().alphaValue = current.isEmpty ? 0 : 1
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if old !== self.cur[self.front] { old.isHidden = true }
        })
    }

    /// 0..1 beat breath: at most +2.5 % size and a slightly wider glow. Slow and small on purpose (photosensitivity rule).
    func breathe(_ b: Double) {
        let v = CGFloat(b)
        guard abs(v - breath) > 0.02 else { return }
        breath = v
        redraw()
    }

    var currentText: String { texts[front] }
}

/// Small Now Playing card, bottom left: artwork, title, artist, source app, progress, previous / play-pause / next.
final class PlayerCardView: NSView {
    let art = NSImageView()
    let title = NSTextField(labelWithString: "")
    let artist = NSTextField(labelWithString: "")
    let appLabel = NSTextField(labelWithString: "")
    let note = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")
    let progress = ProgressBar()
    let prev = PlayerCardView.button("backward.fill", "Previous track")
    let play = PlayerCardView.button("playpause.fill", "Play / pause")
    let next = PlayerCardView.button("forward.fill", "Next track")
    var onHover: (() -> Void)?
    private(set) var hovering = false
    private var playing = false

    static func button(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.contentTintColor = .white
        b.toolTip = tip
        b.imageScaling = .scaleProportionallyUpOrDown
        return b
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 104))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        layer?.borderWidth = 1
        art.frame = NSRect(x: 12, y: 16, width: 72, height: 72)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true; art.layer?.cornerRadius = 6; art.layer?.masksToBounds = true
        art.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        addSubview(art)
        let x: CGFloat = 96, w: CGFloat = 252
        for (l, y, size, weight, alpha) in [(title, 78, 13.0, NSFont.Weight.semibold, 0.95), (artist, 62, 12.0, .regular, 0.8),
                                             (appLabel, 47, 10.5, .regular, 0.55), (note, 47, 10.5, .regular, 0.55)] as [(NSTextField, CGFloat, CGFloat, NSFont.Weight, CGFloat)] {
            l.frame = NSRect(x: x, y: y, width: w, height: 16)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = NSColor(white: 1, alpha: alpha)
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
        }
        note.alignment = .right
        progress.frame = NSRect(x: x, y: 38, width: w, height: 4)
        addSubview(progress)
        time.frame = NSRect(x: x, y: 16, width: 90, height: 14)
        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        time.textColor = NSColor(white: 1, alpha: 0.55)
        addSubview(time)
        for (i, b) in [prev, play, next].enumerated() {
            b.frame = NSRect(x: x + w - 96 + CGFloat(i) * 34, y: 10, width: 26, height: 22)
            addSubview(b)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { hovering = true; onHover?() }
    override func mouseExited(with e: NSEvent) { hovering = false; onHover?() }
    override func mouseMoved(with e: NSEvent) { onHover?() }

    func update(_ i: NowPlayingInfo?, app: String) {
        guard let i else { return }
        title.stringValue = i.title
        artist.stringValue = i.artist
        appLabel.stringValue = app
        if playing != i.playing || play.image == nil {
            playing = i.playing
            play.image = NSImage(systemSymbolName: i.playing ? "pause.fill" : "play.fill", accessibilityDescription: i.playing ? "Pause" : "Play")
        }
    }

    func setArtwork(_ d: Data?) {
        art.image = d.flatMap { NSImage(data: $0) } ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        art.contentTintColor = NSColor(white: 1, alpha: 0.5)
    }

    func setNote(_ s: String?) {
        let v = s ?? ""
        if note.stringValue != v { note.stringValue = v }
        // the source app name shares the line: shorten it when there is a note
        appLabel.frame.size.width = v.isEmpty ? 252 : 110
        note.frame = NSRect(x: 96 + 252 - 150, y: 47, width: 150, height: 16)
    }

    func setProgress(position: Double, duration: Double?, playing: Bool) {
        let d = duration ?? 0
        progress.fraction = d > 0 ? CGFloat(position / d) : 0
        let s = Self.mmss(position) + (d > 0 ? " / " + Self.mmss(d) : "")
        if time.stringValue != s { time.stringValue = s }
    }

    static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class ProgressBar: NSView {
    var fraction: CGFloat = 0 { didSet { if abs(fraction - oldValue) > 0.0005 { needsDisplay = true } } }
    override func draw(_ r: NSRect) {
        let b = bounds
        NSColor(white: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()
        let f = max(0, min(1, fraction))
        guard f > 0 else { return }
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: b.minX, y: b.minY, width: b.width * f, height: b.height), xRadius: b.height / 2, yRadius: b.height / 2).fill()
    }
}
