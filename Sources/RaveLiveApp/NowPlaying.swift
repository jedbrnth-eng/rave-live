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
struct NowPlayingStream {
    private var payload: [String: Any] = [:]

    /// Returns false (state unchanged) for anything that isn't a valid data line.
    mutating func feed(_ line: Data, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data", let p = obj["payload"] as? [String: Any] else { return false }
        if (obj["diff"] as? Bool) == true {
            let before = info
            for (k, v) in p { if v is NSNull { payload.removeValue(forKey: k) } else { payload[k] = v } }
            // A play/pause flip can arrive a moment before the new elapsed/timestamp. Re-anchor at the position we had,
            // so the clock neither jumps ahead by the pause length (resume) nor snaps back (pause).
            let newTime = p["timestampEpochMicros"] != nil || p["timestamp"] != nil || p["elapsedTimeMicros"] != nil || p["elapsedTime"] != nil
            if let b = before, let nowPlaying = p["playing"] as? Bool, nowPlaying != b.playing, !newTime {
                let pos = b.position(at: now)
                payload.removeValue(forKey: "timestamp"); payload.removeValue(forKey: "elapsedTime")
                payload["elapsedTimeMicros"] = NSNumber(value: pos * 1e6)
                payload["timestampEpochMicros"] = NSNumber(value: now * 1e6)
            }
        } else {
            payload = p.filter { !($0.value is NSNull) }
        }
        return true
    }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private func num(_ k: String) -> Double? { (payload[k] as? NSNumber)?.doubleValue }

    var info: NowPlayingInfo? {
        guard let title = payload["title"] as? String, !title.isEmpty else { return nil }
        let duration = (num("durationMicros").map { $0 / 1e6 } ?? num("duration")).flatMap { $0.isFinite && $0 > 0 && $0 < 1e7 ? $0 : nil }
        let elapsed = num("elapsedTimeMicros").map { $0 / 1e6 } ?? num("elapsedTime") ?? 0
        var ts = num("timestampEpochMicros").map { $0 / 1e6 }
        if ts == nil, let s = payload["timestamp"] as? String { ts = Self.iso.date(from: s)?.timeIntervalSince1970 }
        return NowPlayingInfo(title: title, artist: payload["artist"] as? String ?? "", album: payload["album"] as? String ?? "",
                              bundleID: payload["bundleIdentifier"] as? String ?? "", duration: duration, elapsed: elapsed, timestamp: ts,
                              rate: num("playbackRate") ?? 0, playing: payload["playing"] as? Bool ?? false,
                              artwork: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) })
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

    /// Stops the stream and kills the child (quit, or lyrics and card both switched off).
    func stop() {
        queue.sync { [self] in
            wanted = false; generation += 1
            if let p = process, p.isRunning { p.terminate() }
            process = nil
            if adapter != nil { status = .off }
        }
    }

    private func launch() {
        guard wanted, process == nil, let a = adapter else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [a.script.path, a.framework.path, "stream", "--micros", "--debounce=50"]
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
