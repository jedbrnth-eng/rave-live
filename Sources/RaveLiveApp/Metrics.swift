// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation
import QuartzCore

/// "<screen> max N Hz, target N fps" for the metrics JSON. Declared here, not in main.swift: globals in main.swift are
/// only initialised when its top-level code runs, which never happens in the unit tests.
nonisolated(unsafe) var r_displayInfo = ""

/// Fixed-size log-scale histogram: O(1) insert, O(bins) percentiles, constant memory however long the set runs.
/// Bins grow by 0.2 % from `lo`, so a percentile is within about 0.1 % of the exact value (8.333 ms reads 8.33x ms).
struct LogHistogram {
    static let lo = 1e-5, ratio = 1.002, bins = 7000           // 0.01 ms ... ~12 s
    private static let lnRatio = log(ratio)
    private(set) var counts = [Int](repeating: 0, count: bins)
    private(set) var n = 0

    static func bin(_ v: Double) -> Int {
        guard v.isFinite, v > lo else { return 0 }
        return min(bins - 1, Int(log(v / lo) / lnRatio))
    }
    /// Geometric centre of a bin.
    static func value(_ b: Int) -> Double { lo * pow(ratio, Double(b) + 0.5) }

    mutating func add(_ v: Double) { counts[Self.bin(v)] += 1; n += 1 }

    /// Same rank rule as the old sorted-array version: element `min(n-1, Int(n*q))` of the sorted values.
    func percentile(_ q: Double) -> Double {
        guard n > 0 else { return .nan }
        let rank = min(n - 1, Int(Double(n) * q))
        var seen = 0
        for (b, c) in counts.enumerated() where c > 0 {
            seen += c
            if seen > rank { return Self.value(b) }
        }
        return Self.value(Self.bins - 1)
    }
}

/// Fixed-capacity ring of the most recent values (HUD numbers, present delay).
struct Ring {
    private var buf: [Double]
    private var next = 0
    private(set) var count = 0
    init(capacity: Int) { buf = [Double](repeating: 0, count: max(1, capacity)) }
    var capacity: Int { buf.count }
    mutating func add(_ v: Double) { buf[next] = v; next = (next + 1) % buf.count; count = min(count + 1, buf.count) }
    /// Oldest first.
    func suffix(_ k: Int) -> [Double] {
        let k = min(k, count)
        guard k > 0 else { return [] }
        var out = [Double](); out.reserveCapacity(k)
        var i = (next - k + buf.count) % buf.count
        for _ in 0..<k { out.append(buf[i]); i = (i + 1) % buf.count }
        return out
    }
}

/// Frame / GPU / latency statistics, dumped as JSON for acceptance checks.
///
/// Everything is bounded: whole-run percentiles come from fixed histograms, the HUD reads small rings, and the event
/// list keeps its first `eventHead` entries (the `renderer:t0` line tests align with) plus the most recent ones.
/// `dump` only copies a few small arrays under the lock on the calling (render) thread; the JSON encoding and the file
/// write run on a background queue. Before this, a 2 s dump timer on the main thread sorted up to 200 000 values and
/// stalled the visuals for 70-245 ms every 2 s late in a long set.
final class Metrics: @unchecked Sendable {
    private let lock = NSLock()
    static let recentCapacity = 600
    static let eventHead = 200, eventCap = 2000
    static let maxEventLength = 200

    private var frameHist = LogHistogram(), gpuHist = LogHistogram(), latHist = LogHistogram()
    private var recentFrames = Ring(capacity: recentCapacity), recentGPU = Ring(capacity: recentCapacity)
    private var recentLat = Ring(capacity: recentCapacity)
    private var presents = Ring(capacity: 4096)
    private var framesSeen = 0
    /// Flashes inside the trailing 1 s window and the most seen at once (strobe limiter proof).
    private var flashWindow: [Double] = []
    private var maxFlashes = 0
    private var events: [[String: Any]] = []
    private(set) var eventsDropped = 0
    private var _firstReaction: Double?
    private var _state = "", _sync = ""
    var firstReaction: Double? { get { locked { _firstReaction } } set { locked { _firstReaction = newValue } } }
    var state: String { get { locked { _state } } set { locked { _state = newValue } } }
    var sync: String { get { locked { _sync } } set { locked { _sync = newValue } } }
    let started = Date()
    /// Background queue for encoding + writing; serial, so dumps land in order.
    private let io = DispatchQueue(label: "rave.metrics.dump", qos: .utility)

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    /// The first 30 frames (window setup, shader warm-up) are left out of the whole-run percentiles, as before.
    func frame(interval: Double) {
        locked {
            framesSeen += 1
            recentFrames.add(interval)
            if framesSeen > 30 { frameHist.add(interval) }
        }
    }
    func gpu(_ t: Double) { locked { gpuHist.add(t); recentGPU.add(t) } }
    func latency(_ t: Double) { locked { if t > 0 && t < 1 { latHist.add(t); recentLat.add(t) } } }
    func present(_ t: Double) { locked { presents.add(t) } }
    func presentP50() -> Double { Self.median(locked { presents.suffix(presents.count) }) }
    private static func median(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[a.count / 2] }

    func event(_ name: String, at t: Double) {
        let s = name.count > Self.maxEventLength ? String(name.prefix(Self.maxEventLength)) + "…" : name
        let e: [String: Any] = ["t": t - CACurrentMediaTime() + Date().timeIntervalSince(started), "event": s]
        locked {
            events.append(e)
            if events.count > Self.eventCap {               // keep the head (t0 marker, launch), drop the oldest after it
                let drop = events.count - Self.eventCap
                events.removeSubrange(Self.eventHead..<(Self.eventHead + drop))
                eventsDropped += drop
            }
        }
    }
    func flash(at t: Double) {
        locked {
            flashWindow.append(t)
            if let i = flashWindow.firstIndex(where: { t - $0 < 1.0 }), i > 0 { flashWindow.removeFirst(i) }
            maxFlashes = max(maxFlashes, flashWindow.count)
        }
    }
    var eventCount: Int { locked { events.count } }

    struct Summary { var fps: Double; var frameP50: Double; var frameP95: Double; var frameP99: Double; var gpuP95: Double; var latP50: Double; var latP95: Double; var maxFlashesPerSec: Int; var frames: Int; var latN: Int }

    private static func pct(_ a: [Double], _ q: Double) -> Double { a.isEmpty ? .nan : a.sorted()[min(a.count - 1, Int(Double(a.count) * q))] }

    /// `recent: N` (HUD, 4 Hz) uses the last N values (at most `recentCapacity`); nil = the whole run (histograms).
    func summary(recent: Int? = nil) -> Summary {
        lock.lock()
        let fpsWin = recentFrames.suffix(120)
        let maxF = maxFlashes, frames = framesSeen, latN = latHist.n
        if let k = recent {
            let iv = recentFrames.suffix(k), g = recentGPU.suffix(k), l = recentLat.suffix(k)
            lock.unlock()
            let fps = fpsWin.isEmpty ? 0 : Double(fpsWin.count) / fpsWin.reduce(0, +)
            return Summary(fps: fps, frameP50: Self.pct(iv, 0.5), frameP95: Self.pct(iv, 0.95), frameP99: Self.pct(iv, 0.99),
                           gpuP95: Self.pct(g, 0.95), latP50: Self.pct(l, 0.5), latP95: Self.pct(l, 0.95),
                           maxFlashesPerSec: maxF, frames: frames, latN: latN)
        }
        let fh = frameHist, gh = gpuHist, lh = latHist          // value copies of fixed-size arrays (copy-on-write: no copy here)
        lock.unlock()
        let fps = fpsWin.isEmpty ? 0 : Double(fpsWin.count) / fpsWin.reduce(0, +)
        return Summary(fps: fps, frameP50: fh.percentile(0.5), frameP95: fh.percentile(0.95), frameP99: fh.percentile(0.99),
                       gpuP95: gh.percentile(0.95), latP50: lh.percentile(0.5), latP95: lh.percentile(0.95),
                       maxFlashesPerSec: maxF, frames: frames, latN: latN)
    }

    /// Everything `dump` needs, copied under the lock. Only value copies (copy-on-write buffers: reference bumps, no
    /// element copies here); the percentiles, sorting and encoding happen on the background queue.
    private struct Snapshot {
        var fh: LogHistogram, gh: LogHistogram, lh: LogHistogram
        var frames: Ring, presents: Ring
        var maxF: Int, frameCount: Int, events: [[String: Any]], dropped: Int
        var firstReaction: Double?, state: String, sync: String, display: String, elapsed: Double
    }

    /// Writes the JSON in the background. `wait: true` (quit, `--autoquit`) blocks until the file is on disk.
    /// Returns the time spent on the calling thread (seconds), for the tests.
    @discardableResult
    func dump(to url: URL, wait: Bool = false) -> Double {
        let t0 = CACurrentMediaTime()
        lock.lock()
        let snap = Snapshot(fh: frameHist, gh: gpuHist, lh: latHist, frames: recentFrames, presents: presents,
                            maxF: maxFlashes, frameCount: framesSeen, events: events, dropped: eventsDropped,
                            firstReaction: _firstReaction, state: _state, sync: _sync, display: r_displayInfo,
                            elapsed: Date().timeIntervalSince(started))
        lock.unlock()
        let work = { Self.write(snap, to: url) }
        if wait { io.sync(execute: work) } else { io.async(execute: work) }
        return CACurrentMediaTime() - t0
    }

    /// Blocks until queued background writes are done (tests).
    func flush() { io.sync {} }

    private static func write(_ s: Snapshot, to url: URL) {
        func j(_ v: Double) -> Any { v.isFinite ? v : NSNull() }
        let fpsWin = s.frames.suffix(120)
        let fps = fpsWin.isEmpty ? 0 : Double(fpsWin.count) / fpsWin.reduce(0, +)
        let firstReaction: Any = s.firstReaction.map { j($0 * 1000) } ?? NSNull()
        let d: [String: Any] = [
            "elapsed_s": s.elapsed, "frames": s.frameCount, "fps_recent": j(fps),
            "frame_interval_ms": ["p50": j(s.fh.percentile(0.5) * 1000), "p95": j(s.fh.percentile(0.95) * 1000), "p99": j(s.fh.percentile(0.99) * 1000)],
            "gpu_ms_p95": j(s.gh.percentile(0.95) * 1000),
            "audio_capture_to_photon_ms": ["p50": j(s.lh.percentile(0.5) * 1000), "p95": j(s.lh.percentile(0.95) * 1000), "n": s.lh.n],
            "first_reaction_after_sound_ms": firstReaction,
            "max_strobe_flashes_in_1s": s.maxF,
            "display": s.display,
            "sync": s.sync,
            "draw_to_photon_ms_p50": j(median(s.presents.suffix(s.presents.count)) * 1000),
            "events": s.events, "events_dropped": s.dropped, "state": s.state,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
