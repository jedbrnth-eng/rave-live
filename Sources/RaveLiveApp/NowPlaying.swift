// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import Foundation

/// macOS Now Playing (any player: Spotify, Music, browsers, SoundCloud apps…) through ungive/mediaremote-adapter
/// (BSD-3-Clause). Apple locked MediaRemote to Apple-signed processes in macOS 15.4, so the adapter's framework is
/// loaded by /usr/bin/perl and streams JSON lines on stdout. Optional, like Syphon and projectM: without it the app
/// runs as before and Settings says what is missing.

struct NowPlayingInfo: Equatable {
    var title: String, artist: String, album: String, bundleID: String
    var duration: Double?
    /// Elapsed seconds at `timestamp` (epoch seconds).
    var elapsed: Double, timestamp: Double?
    var rate: Double, playing: Bool
    var artwork: Data?
    /// The player sent no position for this track, so `elapsed`/`timestamp` are our own clock started when it appeared.
    var positionEstimated = false

    /// Playback position at epoch time `now`: elapsed + (now - timestamp) × rate while playing, clamped to the length.
    func position(at now: Double) -> Double {
        guard playing, let ts = timestamp else { return elapsed }
        let r = rate > 0 ? rate : 1
        var p = elapsed + (now - ts) * r
        if let d = duration, d > 0 { p = min(p, d) }
        return max(0, p)
    }

    /// Same song (ignores position, play state, artwork).
    var trackKey: String { "\(bundleID)|\(title)|\(artist)|\(Int((duration ?? 0).rounded()))" }
}

/// Merges the adapter's `stream` lines: `diff:false` replaces the state, `diff:true` updates it, null removes a key.
///
/// Some players stop sending a position. YouTube in Zen (Firefox engine) after an autoplay to the next video nulls the
/// elapsed time and length a second into the song and then sends only new timestamps (recorded 2026-11-17). A missing
/// elapsed time used to read as 0 at the newest timestamp, so every such update restarted the song clock and the lyrics
/// fell a minute behind. Now each track keeps its own clock: the last position the player really sent (and its length),
/// or, if it never sent one, a clock started when the track appeared (`positionEstimated`).
struct NowPlayingStream {
    private var payload: [String: Any] = [:]

    private struct Clock { var elapsed: Double, timestamp: Double, estimated: Bool, duration: Double?, leftAt: Double? }
    /// Per track (`clockID`), for players that send no position. Small: pruned in `feed`.
    private var clocks: [String: Clock] = [:]
    private var currentID: String?
    /// A page can show a half-updated title for a moment (seen: the next video's title with the old channel for 2 s).
    /// Coming back to a track within this long counts as the same play and keeps its clock.
    static let glitchWindow = 15.0

    /// Returns false (state unchanged) for anything that isn't a valid data line.
    mutating func feed(_ line: Data, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data", let p = obj["payload"] as? [String: Any] else { return false }
        let before = info
        if (obj["diff"] as? Bool) == true {
            for (k, v) in p { if v is NSNull { payload.removeValue(forKey: k) } else { payload[k] = v } }
            // A play/pause flip can arrive a moment before the new elapsed/timestamp. Re-anchor at the position we had,
            // so the clock neither jumps ahead by the pause length (resume) nor snaps back (pause).
            let newTime = p["timestampEpochMicros"] != nil || p["timestamp"] != nil || p["elapsedTimeMicros"] != nil || p["elapsedTime"] != nil
            if sourceElapsed != nil, let b = before, let nowPlaying = p["playing"] as? Bool, nowPlaying != b.playing, !newTime {
                let pos = b.position(at: now)
                payload.removeValue(forKey: "timestamp"); payload.removeValue(forKey: "elapsedTime")
                payload["elapsedTimeMicros"] = NSNumber(value: pos * 1e6)
                payload["timestampEpochMicros"] = NSNumber(value: now * 1e6)
            }
        } else {
            payload = p.filter { !($0.value is NSNull) }
        }
        // An elapsed time without its own timestamp was measured about now: anchor it here, or the position would stay
        // frozen at that elapsed time while playing and the lyrics would fall behind until the next update.
        let hasElapsed = p["elapsedTimeMicros"] != nil || p["elapsedTime"] != nil
        let hasStamp = p["timestampEpochMicros"] != nil || p["timestamp"] != nil
        if hasElapsed && !hasStamp {
            payload.removeValue(forKey: "timestamp")
            payload["timestampEpochMicros"] = NSNumber(value: now * 1e6)
        }
        updateClock(before: before, now: now)
        return true
    }

    private mutating func updateClock(before: NowPlayingInfo?, now: Double) {
        let id = clockID
        if currentID != id, let old = currentID { clocks[old]?.leftAt = now }
        defer { currentID = id }
        guard let id else { return }
        var c: Clock?
        if id == currentID { c = clocks[id] }
        else if let old = clocks[id], let left = old.leftAt, now - left <= Self.glitchWindow { c = old }
        let duration = sourceDuration ?? c?.duration
        if let e = sourceElapsed, let ts = sourceTimestamp {
            c = Clock(elapsed: e, timestamp: ts, estimated: false, duration: duration, leftAt: nil)
        } else if var k = c {
            // Play/pause without a position: freeze or resume the clock where it was.
            if id == currentID, let b = before, b.playing != (payload["playing"] as? Bool ?? false) {
                k.elapsed = b.position(at: now); k.timestamp = now
            }
            k.duration = duration; k.leftAt = nil
            c = k
        } else {
            c = Clock(elapsed: 0, timestamp: now, estimated: true, duration: duration, leftAt: nil)
        }
        clocks[id] = c
        if clocks.count > 8 {
            for (k, v) in clocks where k != id && (v.leftAt ?? now) < now - Self.glitchWindow { clocks.removeValue(forKey: k) }
        }
    }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private func num(_ k: String) -> Double? { (payload[k] as? NSNumber)?.doubleValue }
    private var sourceElapsed: Double? { num("elapsedTimeMicros").map { $0 / 1e6 } ?? num("elapsedTime") }
    private var sourceTimestamp: Double? {
        if let t = num("timestampEpochMicros") { return t / 1e6 }
        return (payload["timestamp"] as? String).flatMap { Self.iso.date(from: $0)?.timeIntervalSince1970 }
    }
    private var sourceDuration: Double? {
        (num("durationMicros").map { $0 / 1e6 } ?? num("duration")).flatMap { $0.isFinite && $0 > 0 && $0 < 1e7 ? $0 : nil }
    }
    /// Track identity without the length (players drop and re-send it).
    private var clockID: String? {
        guard let title = payload["title"] as? String, !title.isEmpty else { return nil }
        return "\(payload["bundleIdentifier"] as? String ?? "")|\(title)|\(payload["artist"] as? String ?? "")"
    }

    var info: NowPlayingInfo? {
        guard let title = payload["title"] as? String, !title.isEmpty else { return nil }
        let clock = clockID.flatMap { clocks[$0] }
        var elapsed = sourceElapsed ?? 0, ts = sourceTimestamp, estimated = false
        if sourceElapsed == nil, let c = clock { elapsed = c.elapsed; ts = c.timestamp; estimated = c.estimated }
        return NowPlayingInfo(title: title, artist: payload["artist"] as? String ?? "", album: payload["album"] as? String ?? "",
                              bundleID: payload["bundleIdentifier"] as? String ?? "", duration: sourceDuration ?? clock?.duration,
                              elapsed: elapsed, timestamp: ts,
                              rate: num("playbackRate") ?? 0, playing: payload["playing"] as? Bool ?? false,
                              artwork: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) },
                              positionEstimated: estimated)
    }
}

/// Runs `perl mediaremote-adapter.pl <framework> stream` as a child process, parses its lines off the main thread,
/// restarts it with backoff if it dies, and kills it on quit. Commands (play/pause/next/previous) are one-shot runs.
final class NowPlayingSource {
    enum Status: Equatable { case off, missing, running, restarting(Int), failed(String) }
    struct Adapter { let script: URL; let framework: URL }
    enum Command: Int { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
        var name: String { ["play", "pause", "toggle", "", "next", "previous"][rawValue] } }

    /// Written on `queue` only. The main thread reads `mainStatus`, a copy updated on the main queue.
    private var status: Status = .off { didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.mainStatus = s; self.onStatus?(s) } } } }
    /// Main thread only.
    private(set) var mainStatus: Status = .off
    /// Main queue. nil = no Now Playing app.
    var onChange: ((NowPlayingInfo?) -> Void)?
    var onStatus: ((Status) -> Void)?
    var log: ((String) -> Void)?
    let adapter: Adapter?

    private let queue = DispatchQueue(label: "ravelive.nowplaying")
    private var process: Process?
    private var buffer = Data()
    private var stream = NowPlayingStream()
    private var wanted = false
    private var failures = 0
    private var startedAt = Date()
    private var lastInfo: NowPlayingInfo?
    private var launches = 0
    /// Bumped by start()/stop(); a restart queued under an older generation is dropped.
    private var generation = 0

    // test hooks
    var debugPID: Int32? { queue.sync { process.map { $0.processIdentifier } } }
    var debugLaunches: Int { queue.sync { launches } }
    func debugForceFailed() { queue.sync { wanted = true; status = .failed("test") } }

    init(adapter: Adapter? = NowPlayingSource.locate()) {
        self.adapter = adapter
        if adapter == nil { status = .missing; mainStatus = .missing }
    }

    /// Bundled adapter (Contents/Resources/MediaRemoteAdapter + Contents/Frameworks), or `RAVE_MEDIAREMOTE_DIR`
    /// (a folder holding both, e.g. vendor/mediaremote-adapter) for runs from `swift build`.
    static func locate() -> Adapter? {
        let fm = FileManager.default
        var cands: [Adapter] = []
        if let d = ProcessInfo.processInfo.environment["RAVE_MEDIAREMOTE_DIR"] {
            let u = URL(fileURLWithPath: NSString(string: d).expandingTildeInPath)
            cands.append(Adapter(script: u.appendingPathComponent("mediaremote-adapter.pl"), framework: u.appendingPathComponent("MediaRemoteAdapter.framework")))
        } else if let res = Bundle.main.resourceURL, let fw = Bundle.main.privateFrameworksURL {
            cands.append(Adapter(script: res.appendingPathComponent("MediaRemoteAdapter/mediaremote-adapter.pl"), framework: fw.appendingPathComponent("MediaRemoteAdapter.framework")))
        }
        return cands.first { fm.fileExists(atPath: $0.script.path) && fm.fileExists(atPath: $0.framework.appendingPathComponent("MediaRemoteAdapter").path) }
    }

    static func backoff(failures: Int) -> Double { min(30, pow(2, Double(max(0, failures)))) }

    func start() {
        queue.async { [self] in
            guard adapter != nil else { return }
            if case .failed = status { wanted = false }            // switching on again after a failure retries
            guard !wanted else { return }
            wanted = true; failures = 0; generation += 1
            launch()
        }
    }

    /// Stops the stream and kills the child (quit, or lyrics and card both switched off). The adapter can miss a
    /// SIGTERM that lands in its first milliseconds (quick Y/N toggles left orphans that ran for minutes), so a child
    /// still alive after `grace` gets SIGKILL. `waitForExit` (quit) blocks until it is gone instead of scheduling that.
    func stop(waitForExit: Bool = false) {
        queue.sync { [self] in
            wanted = false; generation += 1
            if let p = process { Self.terminate(p, grace: 0.3, on: waitForExit ? nil : queue) }
            process = nil
            if adapter != nil { status = .off }
        }
    }

    /// SIGTERM now, SIGKILL after `grace` if the child is still running. The closure keeps `p` (and so its pid, which
    /// Foundation hasn't reaped yet) alive until then. `queue` nil = wait here.
    static func terminate(_ p: Process, grace: Double, on queue: DispatchQueue?) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        p.terminate()
        let finish = { if p.isRunning { kill(pid, SIGKILL) } }
        if let q = queue { q.asyncAfter(deadline: .now() + grace, execute: finish); return }
        let end = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < end { usleep(10_000) }
        finish()
    }

    /// Parent-death watch, run by /usr/bin/perl in front of the adapter. It forks a tiny watcher, then `exec`s the
    /// adapter in place (same pid, so `Process` still tracks and signals the adapter itself, and the pipes go to it).
    /// The watcher checks twice a second: adapter gone -> exit; RAVE LIVE gone (quit, crash, force quit) -> SIGTERM the
    /// adapter, then SIGKILL. Without it a crashed app left the adapter running with PPID 1.
    static let watchdog = #"""
    my $app = getppid(); my $me = $$;
    my $w = fork();
    if (defined $w && $w == 0) {
      open(STDIN, '<', '/dev/null'); open(STDOUT, '>', '/dev/null'); open(STDERR, '>', '/dev/null');
      while (1) {
        select(undef, undef, undef, 0.5);
        exit 0 if getppid() != $me;
        if (!kill(0, $app)) { kill('TERM', $me); select(undef, undef, undef, 0.3); kill('KILL', $me); exit 0; }
      }
    }
    exec('/usr/bin/perl', @ARGV) or exit 127;
    """#

    /// `/usr/bin/perl` arguments that start the streaming adapter under the watchdog.
    static func launchArguments(_ a: Adapter) -> [String] {
        ["-e", watchdog, "--", a.script.path, a.framework.path, "stream", "--micros", "--debounce=50"]
    }

    private func launch() {
        guard wanted, process == nil, let a = adapter else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = Self.launchArguments(a)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        buffer.removeAll(); stream = NowPlayingStream()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            self.queue.async { self.consume(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { self?.log?("nowplaying: adapter stderr: " + s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
            self?.queue.async { self?.died(proc) }
        }
        do {
            try p.run()
            process = p; startedAt = Date(); status = .running; launches += 1
            log?("nowplaying: adapter started (pid \(p.processIdentifier))")
        } catch {
            log?("nowplaying: adapter failed to start: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func died(_ p: Process) {
        guard p === process || process == nil else { return }
        process = nil
        guard wanted else { return }
        log?("nowplaying: adapter exited (status \(p.terminationStatus)) after \(Int(Date().timeIntervalSince(startedAt))) s")
        publish(nil)
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 }
        scheduleRestart()
    }

    private func scheduleRestart() {
        // Five quick deaths in a row: the adapter is broken on this macOS. Stop instead of spinning (its README asks not to loop).
        if failures >= 5 { status = .failed("the Now Playing reader keeps stopping on this macOS version"); return }
        let wait = Self.backoff(failures: failures)
        failures += 1
        status = .restarting(failures)
        let g = generation
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.generation == g else { return }      // stale: stop()/start() ran in between
            self.launch()
        }
    }

    private func consume(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        var changed = false
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if stream.feed(line) { changed = true }
        }
        if buffer.count > 16 << 20 { buffer.removeAll() }     // never grow without bound on a broken stream
        if changed { publish(stream.info) }
    }

    private func publish(_ i: NowPlayingInfo?) {
        guard i != lastInfo else { return }
        lastInfo = i
        DispatchQueue.main.async { self.onChange?(i) }
    }

    /// Sends play/pause/next/previous to the Now Playing app (one-shot `send N`, off the main thread).
    func send(_ c: Command) {
        guard let a = adapter else { log?("nowplaying: send \(c.name) ignored (adapter missing)"); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [a.script.path, a.framework.path, "send", String(c.rawValue)]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); self?.log?("nowplaying: send \(c.name) -> exit \(p.terminationStatus)") }
            catch { self?.log?("nowplaying: send \(c.name) failed: \(error.localizedDescription)") }
        }
    }

    /// "Spotify", "Music", … for a bundle id (falls back to the id).
    static func appName(_ bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "" }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
