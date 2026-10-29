// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import QuartzCore

/// Synced lyrics overlay + Now Playing card. Both are AppKit views over the main window (like the HUD), so they never
/// reach Syphon or the output display. Follow-up: an option to burn lyrics into the output frame.
final class LyricsController: NSObject {
    enum LyricsState: Equatable { case off, waiting, looking, busy, synced, remix, lengthDiffers, longVideo, noLength, instrumental, notFound, offline }

    /// What the hint line and the card need to explain the state: the two lengths compared, whether the source is a video
    /// (browser), the intro offset in use, whether the user forced the sync, and the key that forces it ("L", or "Shift-L"
    /// in MILKDROP where L locks the preset).
    struct HintContext: Equatable {
        var trackDuration: Double?, matchDuration: Double?
        var video: Bool, introOffset: Double, forced: Bool, forceKey: String
    }

    static func mmss(_ t: Double?) -> String { t.map { PlayerCardView.mmss($0) } ?? "?" }

    /// One line where the lyrics would be. Never a silent nothing: every state that shows no lyrics says why.
    /// nil while plain synced lyrics are showing (the lyrics are the message).
    static func hint(_ s: LyricsState, _ c: HintContext) -> String? {
        let anyway = "Press \(c.forceKey) to sync anyway"
        switch s {
        case .waiting: return nil
        case .off: return "Lyrics off (Y)"
        case .looking: return "Looking up lyrics…"
        case .busy: return "Lyrics server busy, retrying"
        case .offline: return "Lyrics offline, retrying"
        case .notFound: return "No synced lyrics found"
        case .instrumental: return "Instrumental: no lyrics"
        case .remix: return "Skipped: remix/edit. " + anyway
        case .noLength: return "Skipped: the player reports no track length. " + anyway
        case .longVideo: return "Skipped: long video/mix (\(mmss(c.trackDuration)), the song is \(mmss(c.matchDuration))). " + anyway
        case .lengthDiffers:
            return "Skipped: \(c.video ? "video" : "track") length \(mmss(c.trackDuration)) doesn't match the song (\(mmss(c.matchDuration))). " + anyway
        case .synced:
            if c.forced { return "Synced anyway (Shift -/= ±1 s, \(c.forceKey) undoes)" }
            if c.introOffset > 0 { return "Synced with a \(mmss(c.introOffset)) video intro (Shift -/= ±1 s)" }
            return nil
        }
    }

    /// Short version for the player card's note slot (about 26 characters).
    static func cardNote(_ s: LyricsState, _ c: HintContext) -> String? {
        switch s {
        case .waiting: return nil
        case .off: return "lyrics off (Y)"
        case .looking: return "looking up lyrics…"
        case .busy: return "lyrics server busy"
        case .offline: return "lyrics offline"
        case .notFound: return "no synced lyrics"
        case .instrumental: return "instrumental"
        case .remix: return "skipped: remix/edit"
        case .noLength: return "skipped: no track length"
        case .longVideo: return "skipped: long video/mix"
        case .lengthDiffers: return "skipped: length differs"
        case .synced: return c.forced ? "synced anyway (\(c.forceKey))" : (c.introOffset > 0 ? "synced (+\(mmss(c.introOffset)) intro)" : "lyrics: lrclib.net")
        }
    }

    /// Full-HUD "Lyrics" debug: source app, the cleaned title/artist that were looked up, the lengths compared, the decision.
    /// One row, kept short so the full HUD panel doesn't grow into the lyrics on small windows.
    static func debugLine(app: String, title: String, artist: String, trackDuration: Double?, matchDuration: Double?, decision: String, offset: Double) -> String {
        let t = title.count > 24 ? title.prefix(23) + "…" : title
        let a = artist.count > 16 ? artist.prefix(15) + "…" : artist
        return "\(app) · \"\(t)\" / \(a) · \(mmss(trackDuration)) vs \(mmss(matchDuration)) · \(decision)"
            + (abs(offset) > 0.05 ? String(format: " · offset %+.1f s", offset) : "")
    }

    private weak var app: AppDelegate?
    let source: NowPlayingSource
    private let client = LRCLIBClient()
    private let cache = LyricsCache(dir: LyricsCache.defaultDir)
    let overlay = LyricsOverlayView()
    let card = PlayerCardView()
    let hintLabel = LyricsHintView()
    private var timer: Timer?
    /// Test hook (`lineshot=`): runs once at the next change to a new non-empty line.
    var onNextLineChange: (() -> Void)?
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
    /// Offline retries for the current song (backoff 30 s, 60 s, 120 s … 10 min); reset on a new song or an answer.
    private var retries = 0, retryKey = ""
    private var hudLevel: OverlayLevel = .status
    private var logURL: URL?
    // What the last lookup found and decided for the current track (hint line, HUD debug row, L / Shift -/=).
    private var matchDuration: Double?
    private var gate: LyricsGate?
    private var pendingRecord: LRCLIBRecord?, pendingKey = ""
    /// Track key the user forced with L (sync a skipped song anyway).
    private var forcedKey: String?
    /// Video intro estimate (gate) and the user's Shift -/= steps, both per track, never saved.
    private(set) var introOffset = 0.0, videoNudge = 0.0
    private var lookupTitle = "", lookupArtist = ""
    private var busyRetryAfter: Double?
    /// When the hint text last changed: it shows for `hintSeconds` after that, and again whenever the mouse moves.
    private var hintChangedAt = -100.0
    private var lastHint: String?
    static let hintSeconds = 8.0
    /// MILKDROP keeps plain L for its preset lock, so the hint names the key that works in the current mode.
    var forceKey: String { app?.renderer?.mode == .milkdrop ? "Shift-L" : "L" }

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
        cv.addSubview(hintLabel, positioned: .above, relativeTo: overlay)
        hintLabel.isHidden = true
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

    func shutdown() { timer?.invalidate(); lookupTask?.cancel(); source.stop(waitForExit: true) }

    /// `redacted` replaces `s` in the system log and the metrics JSON (written to ~/.cache by default and kept for the
    /// whole run): track titles and artists only go to the opt-in `--lyrics-log` test file.
    func log(_ s: String, redacted: String? = nil) {
        NSLog("RAVE LIVE %@", redacted ?? s)
        app?.renderer?.metrics.event(redacted ?? s, at: CACurrentMediaTime())
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
            return "Now Playing: \(i.title) — \(NowPlayingSource.appName(i.bundleID))" + (Self.cardNote(state, hintContext).map { " · \($0)" } ?? "")
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

    /// One 30 Hz step of the card fade: eases toward visible while awake, toward 0 otherwise. A faded-out card is
    /// hidden: an invisible card would still catch clicks meant for the visuals (and could pause the music), and
    /// window snapshots draw subviews regardless of alpha. Any mouse movement wakes it again.
    static func cardStep(alpha: CGFloat, want: Bool, awake: Bool) -> (alpha: CGFloat, hidden: Bool) {
        guard want else { return (0, true) }
        let a = alpha + ((awake ? 1 : 0) - alpha) * 0.15
        return (a, !awake && a < 0.02)
    }

    // MARK: Now Playing -> lyrics

    /// Test hook: report the Now Playing source as this bundle id (e2e runs make the silent fake player look like a
    /// browser without registering a second app under a real browser's id).
    static let testSourceBundle = ProcessInfo.processInfo.environment["RAVE_TEST_NP_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 }

    private func nowPlayingChanged(_ i: NowPlayingInfo?) {
        var i = i
        if let b = Self.testSourceBundle { i?.bundleID = b }
        let old = info
        info = i
        if old?.trackKey != i?.trackKey {
            if let i {
                log(String(format: "nowplaying: track \"%@\" — %@ (%@) %.1f s", i.title, i.artist, i.bundleID, i.duration ?? -1),
                    redacted: String(format: "nowplaying: track %@ (%@) %.1f s", Self.titleTag(i.title, i.artist), i.bundleID, i.duration ?? -1))
            }
            else { log("nowplaying: nothing playing") }
            wake(); lines = []; shownIndex = -1; lookupKey = ""; shownPair = ("\u{1}", "\u{1}")
            lookupTask?.cancel(); lookupTask = nil
            matchDuration = nil; gate = nil; pendingRecord = nil; pendingKey = ""; introOffset = 0; videoNudge = 0; busyRetryAfter = nil
            lookupTitle = ""; lookupArtist = ""
            hintChangedAt = CACurrentMediaTime()
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
        hintChangedAt = CACurrentMediaTime()
        log("lyrics: state \(s)" + (Self.hint(s, hintContext).map { " (\($0))" } ?? ""))
        app?.settings?.refresh()
    }

    var isVideo: Bool { info.map { TrackTitle.isBrowser($0.bundleID) } ?? false }
    private var currentKey: String? { info.map { LyricsCache.key(title: $0.title, artist: $0.artist, duration: $0.duration) } }
    private var isForced: Bool { forcedKey != nil && forcedKey == currentKey }
    var hintContext: HintContext {
        HintContext(trackDuration: info?.duration, matchDuration: matchDuration, video: isVideo, introOffset: introOffset, forced: isForced, forceKey: forceKey)
    }
    /// The hint line text for the current state (nil = nothing to add).
    var hintText: String? { info == nil ? nil : Self.hint(state, hintContext) }

    /// Full-HUD "Lyrics" row (also logged with each `shot`).
    var hudDebug: String {
        guard source.adapter != nil else { return "Now Playing reader not in this build" }
        guard let i = info else { return lyricsOn ? "nothing playing" : "lyrics off (Y) · nothing playing" }
        let decision: String
        switch state {
        case .off: decision = "lyrics off (Y)"
        case .waiting: decision = "waiting"
        case .looking: decision = "looking up"
        case .busy: decision = "server busy, retrying"
        case .offline: decision = "offline, retrying"
        case .notFound: decision = "no synced lyrics"
        case .instrumental: decision = "instrumental"
        case .noLength: decision = "skipped: no length"
        case .synced: decision = isForced ? "forced (L)" : (introOffset > 0 ? "intro assumed" : "synced")
        case .remix: decision = "skipped: remix"
        case .lengthDiffers: decision = "skipped: length"
        case .longVideo: decision = "skipped: long video"
        }
        var t = lookupTitle, a = lookupArtist
        if t.isEmpty { let x = TrackTitle.lookupIdentity(title: i.title, artist: i.artist, bundleID: i.bundleID); t = x.title; a = x.artist }
        return Self.debugLine(app: NowPlayingSource.appName(i.bundleID), title: t, artist: a, trackDuration: i.duration,
                              matchDuration: matchDuration, decision: decision, offset: introOffset + videoNudge)
    }

    /// L: sync a skipped song anyway, or undo that. Returns the status line to flash.
    func toggleForce() -> String {
        guard lyricsOn else { return "Lyrics are off: Y turns them on" }
        guard let i = info, let key = currentKey else { return "Nothing is playing" }
        if forcedKey == key {
            forcedKey = nil; videoNudge = 0
            log("lyrics: force off")
            lookupKey = ""; refreshLyrics()
            hintChangedAt = CACurrentMediaTime()
            return "Lyrics back to automatic"
        }
        switch state {
        case .remix, .lengthDiffers, .longVideo, .noLength: break
        case .synced: return "Lyrics already synced: Shift -/= moves them 1 s"
        default: return Self.hint(state, hintContext) ?? "Nothing to sync"
        }
        forcedKey = key; videoNudge = 0
        log("lyrics: force on (\(state))")
        if let rec = pendingRecord, pendingKey == key { apply(.synced(rec), for: i) }
        else { lookupKey = ""; refreshLyrics() }                // remix / no length: never looked up yet
        hintChangedAt = CACurrentMediaTime()
        return "Syncing anyway: Shift -/= moves the lyrics 1 s"
    }

    /// Shift -/=: move the lyrics by whole seconds for this video (intro estimate off, or a forced sync). Not saved.
    func nudgeVideo(_ seconds: Double) -> String {
        videoNudge = max(-600, min(600, videoNudge + seconds))
        hintChangedAt = CACurrentMediaTime()
        log(String(format: "lyrics: video offset %.1f s (intro %.1f + nudge %.1f)", introOffset + videoNudge, introOffset, videoNudge))
        return String(format: "Lyrics %+.0f s for this song (total offset %+.1f s)", videoNudge, introOffset + videoNudge)
    }

    private func refreshLyrics() {
        guard lyricsOn, let i = info else { setState(.off); return }
        let key = LyricsCache.key(title: i.title, artist: i.artist, duration: i.duration)
        guard key != lookupKey else { return }
        lookupKey = key; retryAt = nil
        if key != retryKey { retryKey = key; retries = 0 }
        let forced = forcedKey == key
        let id = TrackTitle.lookupIdentity(title: i.title, artist: i.artist, bundleID: i.bundleID)
        lookupTitle = id.title; lookupArtist = id.artist
        if !forced, TrackTitle.hasRemixMarker(id.videoTitle) { setState(.remix); return }    // remixes are never looked up
        let d = i.duration.flatMap { $0 > 0 ? $0 : nil }
        if !forced, d == nil { setState(.noLength); return }
        if let hit = cache.load(key) { log("lyrics: cache hit \(key)"); apply(hit, for: i); return }
        setState(.looking)
        log("lyrics: lookup \"\(TrackTitle.clean(id.title, strict: false))\" / \(TrackTitle.cleanArtist(id.artist)) / \(d.map { "\(Int($0.rounded())) s" } ?? "no length") from \(i.bundleID)",
            redacted: "lyrics: lookup \(Self.titleTag(i.title, i.artist)) / \(d.map { "\(Int($0.rounded())) s" } ?? "no length") from \(i.bundleID)")
        let t0 = CACurrentMediaTime()
        lookupTask?.cancel()
        lookupTask = Task { [client] in
            let busy: @Sendable () -> Void = { [weak self] in
                DispatchQueue.main.async { guard let self, self.lookupKey == key, self.state == .looking else { return }; self.setState(.busy) }
            }
            let l = await client.lookupDetailed(title: id.title, artist: id.artist, album: i.album, duration: d, onBusy: busy)
            await MainActor.run { [weak self] in
                guard let self, self.lookupKey == key, !Task.isCancelled else { return }
                let r = l.result
                self.log(String(format: "lyrics: lookup done in %.2f s -> %@%@", CACurrentMediaTime() - t0, Self.describe(r), l.cacheable ? "" : " (not cached)"))
                var gate: LyricsGate?
                if case .synced(let rec) = r { gate = LyricsGate.decide(rawTitle: id.videoTitle, trackDuration: i.duration, matchDuration: rec.duration, video: TrackTitle.isBrowser(i.bundleID)) }
                if LyricsCache.shouldStore(r, cacheable: l.cacheable, gate: gate) { self.cache.store(r, key) }
                self.apply(r, for: i, retryAfter: l.retryAfter)
            }
        }
    }

    /// 30 s, 60 s, 120 s … capped at 10 min: a dead or always-500 server isn't hammered for the whole song.
    static func retryDelay(attempt: Int) -> Double { retryDelay(attempt: attempt, busy: false, retryAfter: nil) }
    /// Busy (LRCLIB overloaded): 10 s, 20 s, 40 s … 10 min, and never sooner than the server's `Retry-After`.
    static func retryDelay(attempt: Int, busy: Bool, retryAfter: Double?) -> Double {
        let n = Double(min(10, max(0, attempt)))
        let base = min(600, (busy ? 10 : 30) * pow(2, n))
        return max(base, min(3600, retryAfter ?? 0))
    }

    /// Short stable tag for a track in logs that persist ("track#1a2b3c4d"): FNV-1a of title + artist, no text.
    static func titleTag(_ title: String, _ artist: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (title + "\u{1f}" + artist).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "track#%08llx", h & 0xffff_ffff)
    }

    static func describe(_ r: LyricsResult) -> String {
        switch r {
        case .synced(let rec): return "synced id \(rec.id) (\(rec.duration.map { String(format: "%.1f s", $0) } ?? "no length"))"
        default: return "\(r)"
        }
    }

    private func apply(_ r: LyricsResult, for i: NowPlayingInfo, retryAfter: Double? = nil) {
        switch r {
        case .synced(let rec):
            let video = TrackTitle.isBrowser(i.bundleID)
            let id = TrackTitle.lookupIdentity(title: i.title, artist: i.artist, bundleID: i.bundleID)
            let g = LyricsGate.decide(rawTitle: id.videoTitle, trackDuration: i.duration, matchDuration: rec.duration, video: video)
            matchDuration = rec.duration; gate = g
            pendingRecord = rec; pendingKey = LyricsCache.key(title: i.title, artist: i.artist, duration: i.duration)
            let forced = isForced
            log(String(format: "lyrics: gate %@%@ · track %.1f s vs match %.1f s · video %@ · record %d",
                       g.decision, forced ? " (forced by user)" : "", i.duration ?? -1, rec.duration ?? -1, video ? "yes" : "no", rec.id))
            var sync = forced
            introOffset = 0
            switch g {
            case .show: sync = true
            case .intro(let s): sync = true; introOffset = s
            case .remix: if !forced { setState(.remix) }
            case .lengthDiffers: if !forced { setState(.lengthDiffers) }
            case .longVideo: if !forced { setState(.longVideo) }
            case .noLength: if !forced { setState(.noLength) }
            }
            if sync {
                lines = LRC.parse(rec.syncedLyrics ?? ""); shownIndex = -1; shownPair = ("\u{1}", "\u{1}")
                setState(lines.isEmpty ? .notFound : .synced)
                hintChangedAt = CACurrentMediaTime()
                log("lyrics: \(lines.count) synced lines, match \(String(format: "%.1f", rec.duration ?? 0)) s vs track \(String(format: "%.1f", i.duration ?? 0)) s, intro offset \(String(format: "%.1f", introOffset)) s")
            }
        case .instrumental: setState(.instrumental)
        case .plainOnly, .notFound: setState(.notFound)
        case .offline, .busy:
            let busy = r == .busy
            setState(busy ? .busy : .offline)
            busyRetryAfter = retryAfter
            let wait = Self.retryDelay(attempt: retries, busy: busy, retryAfter: retryAfter)
            log(String(format: "lyrics: %@, retry in %.0f s", busy ? "server busy" : "offline", wait))
            retryAt = CACurrentMediaTime() + wait                 // same song still on: try again later
            retries += 1
            return
        }
        retries = 0
    }

    /// Song position the listener hears now: adapter position minus the audio output latency, minus the user trim.
    func heardPosition() -> Double? {
        guard let i = info else { return nil }
        return LyricsTiming.heardPosition(sourcePosition: i.position(at: Date().timeIntervalSince1970), bundleID: i.bundleID,
                                          outputLatency: app?.renderer?.outputLatency.seconds ?? 0, userOffsetMs: offsetMs,
                                          videoOffset: state == .synced ? introOffset + videoNudge : 0)
    }

    /// Test log line for snapshots: position, the line index and its LRC timestamp.
    func describeNow(_ tag: String) {
        let pos = info.map { $0.position(at: Date().timeIntervalSince1970) } ?? -1
        let heard = heardPosition() ?? -1
        let idx = LyricsTiming.lineIndex(heard: heard, in: lines)
        // which LRC line the overlay's text actually is (first line with that text at or before `heard`)
        let shownText = overlay.currentText
        let shownIdx = overlay.isHidden || shownText.isEmpty ? nil : lines.indices.last { lines[$0].text == shownText && lines[$0].time <= heard + 0.5 }
        log(String(format: "lyrics: %@ pos=%.3f heard=%.3f latency=%.0fms offset=%dms state=%@ expectedLine=%@ expectedTime=%@ shownLine=%@ shownTime=%@ overlay=%@ breath=%.3f card=%@",
                   tag, pos, heard, (app?.renderer?.outputLatency.seconds ?? 0) * 1000, offsetMs, "\(state)",
                   idx.map(String.init) ?? "none", idx.map { String(format: "%.2f", lines[$0].time) } ?? "-",
                   shownIdx.map(String.init) ?? "none", shownIdx.map { String(format: "%.2f", lines[$0].time) } ?? "-",
                   overlay.isHidden ? "hidden" : "visible", overlay.lineScale, card.isHidden ? "hidden" : String(format: "visible(alpha %.2f)", card.alphaValue)))
        log("lyrics: \(tag) hint=\(hintLabel.isHidden ? "hidden" : "\"" + hintLabel.text + "\"") cardNote=\"\(card.note.stringValue)\" offsetTotal=\(String(format: "%.1f", introOffset + videoNudge)) debug=\(hudDebug)")
    }

    // MARK: per frame (30 Hz)

    private func tick() {
        let now = CACurrentMediaTime()
        if let r = retryAt, now > r, state == .offline || state == .busy { lookupKey = ""; retryAt = nil; refreshLyrics() }
        let clean = hudLevel == .clean
        // card: visible for a few seconds after mouse movement / a track or play-state change
        let awake = now - lastWake < 4
        let wantCard = cardOn && info != nil && !clean && source.adapter != nil
        let (alpha, hidden) = Self.cardStep(alpha: card.alphaValue, want: wantCard, awake: awake || card.hovering)
        if hidden && !card.isHidden { card.resetHover() }   // a hidden view gets no mouseExited
        card.alphaValue = alpha
        card.isHidden = hidden
        if wantCard {
            card.setNote(Self.cardNote(state, hintContext))
            if let i = info { card.setProgress(position: i.position(at: Date().timeIntervalSince1970), duration: i.duration, playing: i.playing) }
        }
        // hint line: why there are no lyrics (or how the video is synced), for a few seconds after a change or a mouse move
        let h = hintText
        if h != lastHint { lastHint = h; hintChangedAt = now }
        let showHint = h != nil && !clean && source.adapter != nil && (awake || card.hovering || now - hintChangedAt < Self.hintSeconds)
        if showHint, let h {
            if hintLabel.text != h { hintLabel.text = h }
            positionHint()
        }
        hintLabel.isHidden = !showHint
        // lyrics
        let wantLyrics = lyricsOn && state == .synced && info != nil && !clean
        overlay.isHidden = !wantLyrics
        guard wantLyrics, let heard = heardPosition() else { return }
        let idx = LyricsTiming.lineIndex(heard: heard, in: lines)
        if idx != shownIndex, let n = idx, logURL != nil, let i = info {      // test log: when each line went up
            log(String(format: "lyrics: linechange idx=%d lrc=%.3f src=%.3f heard=%.3f latency=%.0fms tsAge=%.3f", n, lines[n].time,
                       i.position(at: Date().timeIntervalSince1970), heard, (app?.renderer?.outputLatency.seconds ?? 0) * 1000,
                       i.timestamp.map { Date().timeIntervalSince1970 - $0 } ?? -1))
        }
        shownIndex = idx
        let cur = idx.map { lines[$0].text } ?? ""
        let nextIdx = (idx ?? -1) + 1
        var nextText = nextIdx < lines.count ? lines[nextIdx].text : ""
        if cur.isEmpty && nextIdx < lines.count && lines[nextIdx].time - heard > Self.nextLineLead { nextText = "" }
        if cur != shownPair.0 || nextText != shownPair.1 {
            let changed = cur != shownPair.0 && !cur.isEmpty
            shownPair = (cur, nextText)
            overlay.show(current: cur, next: nextText)
            if changed, let f = onNextLineChange { onNextLineChange = nil; f() }
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
        positionHint()
    }

    /// Centred where the lyrics go; above them while synced lines can show (intro / forced notes).
    private func positionHint() {
        guard let cv = app?.window.contentView else { return }
        let s = hintLabel.fittingSize
        let w = min(cv.bounds.width - 24, s.width)
        // synced: just under the lyrics (above them it can sit under the full HUD panel); otherwise where the line would be
        var y = state == .synced ? max(4, overlay.frame.minY - s.height - 4) : overlay.frame.minY + overlay.frame.height * 0.3
        var f = NSRect(x: ((cv.bounds.width - w) / 2).rounded(), y: y.rounded(), width: w, height: s.height)
        if state == .synced, !card.isHidden, f.intersects(card.frame.insetBy(dx: -6, dy: -6)) {   // small window: go above the lyrics
            y = overlay.frame.maxY + 4; f.origin.y = y.rounded()
        }
        if hintLabel.frame != f { hintLabel.frame = f }
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

    func preferredHeight(for b: NSRect) -> CGFloat { b.height * scale * 3.9 }

    /// Readable over any visual without a shape behind the text (Jed 10-29: no dark oval): every glyph gets a thin dark
    /// outline and a tight dark shadow, so white text holds on white-ish frames and the picture shows between the words.
    static func attributed(_ s: String, size px: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSAttributedString {
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.75 * alpha)
        sh.shadowBlurRadius = max(2, px * 0.07)
        sh.shadowOffset = NSSize(width: 0, height: -max(1, px * 0.02))
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: px, weight: weight),
                                                          .foregroundColor: NSColor(white: 1, alpha: alpha),
                                                          .strokeColor: NSColor(white: 0, alpha: 0.6 * alpha), .strokeWidth: -3.0,
                                                          .shadow: sh, .paragraphStyle: p])
    }

    func layoutLines() {
        let w = bounds.width * 0.8, x = (bounds.width - w) / 2
        big = max(14, (window?.contentView?.bounds.height ?? bounds.height * 3) * scale)
        let small = big * 0.55
        next.frame = NSRect(x: x, y: 0, width: w, height: small * 1.5)
        for l in cur { l.frame = NSRect(x: x, y: small * 1.5, width: w, height: big * 2.5) }
        redraw()
    }

    /// Builds the attributed strings. Only on a new line or a resize: the beat breath is a layer transform
    /// (`applyBreath`), so the text isn't laid out and shadow-blurred again 30 times a second (that roughly doubled
    /// the app's CPU with lyrics on).
    private func redraw() {
        redraws += 1
        for (i, l) in cur.enumerated() {
            l.attributedStringValue = Self.attributed(texts[i], size: big, weight: .bold, alpha: 1)
        }
        next.attributedStringValue = Self.attributed(nextText, size: big * 0.55, weight: .medium, alpha: 0.6)
        applyBreath()
    }

    /// Scale the current line about its centre by `breathScale(breath)`. Core Animation applies it on the GPU.
    private func applyBreath() {
        let k = Self.breathScale(breath)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in cur {
            guard let layer = l.layer else { continue }
            let b = layer.bounds, ax = b.width * layer.anchorPoint.x, ay = b.height * layer.anchorPoint.y
            let cx = b.midX - ax, cy = b.midY - ay        // centre relative to the anchor (AppKit puts it at the corner)
            var t = CATransform3DMakeTranslation(cx, cy, 0)
            t = CATransform3DScale(t, k, k, 1)
            layer.transform = CATransform3DTranslate(t, -cx, -cy, 0)
        }
        CATransaction.commit()
    }
    /// +2.5 % at the peak of the beat.
    static func breathScale(_ b: CGFloat) -> CGFloat { 1 + 0.025 * max(0, min(1, b)) }
    /// Test hook: how many times the attributed strings were rebuilt.
    private(set) var redraws = 0

    /// Line change: the old line fades out first (`fadeOut`), then the new one fades in (`fadeIn`), so two lines never
    /// sit on top of each other (a 0.4 s crossfade read as doubled, smeared text).
    static let fadeOut = 0.12, fadeIn = 0.22
    private var changeToken = 0
    func show(current: String, next n: String) {
        let old = cur[front]
        front = 1 - front
        let new = cur[front]
        texts[front] = current
        nextText = n
        redraw()
        changeToken += 1
        let token = changeToken
        new.alphaValue = 0
        new.isHidden = true
        next.isHidden = n.isEmpty
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            old.animator().alphaValue = 0
            next.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, token == self.changeToken else { return }
            old.isHidden = true
            new.isHidden = current.isEmpty
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fadeIn
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                new.animator().alphaValue = current.isEmpty ? 0 : 1
                self.next.animator().alphaValue = n.isEmpty ? 0 : 1
            })
        })
    }
    /// Test hook: how many current-line fields are showing (never more than one).
    var visibleLineCount: Int {
        cur.filter { !$0.isHidden && max(Float($0.alphaValue), $0.layer?.presentation()?.opacity ?? 0) > 0.01 }.count
    }

    /// 0..1 beat breath: at most +2.5 % size and a slightly wider glow. Slow and small on purpose (photosensitivity rule).
    func breathe(_ b: Double) {
        let v = CGFloat(b)
        guard abs(v - breath) > 0.01 else { return }
        breath = v
        applyBreath()
    }

    var currentText: String { texts[front] }
    /// Scale the beat breath currently applies to the line (1 = none), read back from the layer.
    var lineScale: Double { Double(cur[front].layer?.transform.m11 ?? 1) }
}

/// One small, dim line that explains the lyrics state ("Lyrics off (Y)", "Skipped: long video/mix…"). A plain label
/// with a rounded dark backing so it reads over bright visuals and shows up in `shot=` snapshots.
final class LyricsHintView: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true; invalidateIntrinsicContentSize() }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.82)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }        // never catches clicks meant for the visuals
    override var fittingSize: NSSize { let s = label.fittingSize; return NSSize(width: ceil(s.width) + 24, height: ceil(s.height) + 8) }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 12, dy: 4) }
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
    func resetHover() { hovering = false }

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
        let s = t.isFinite ? max(0, Int(min(t, 1e7).rounded(.down))) : 0
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
