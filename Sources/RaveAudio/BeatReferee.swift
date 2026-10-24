// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// Live "referee": runs Beat This! (CPJKU, MIT) in a Python sidecar on the last ~12 s of audio every
/// ~1.5 s and corrects the fast causal tracker: off-beat phase locks, wrong tempo level (double/half/
/// triplet), and the bar line (downbeat). The causal tracker keeps driving every frame, so the
/// referee's ~100 ms compute time never delays the visuals.
public final class BeatReferee: @unchecked Sendable {
    public struct Report { public var tEnd: Double; public var beats: [Double]; public var downbeats: [Double]; public var ms: Double }
    public struct Status: Sendable {
        public var running = false, reports = 0, phaseFixes = 0, tempoFixes = 0, barFixes = 0, rejected = 0
        public var lastMs = 0.0, refBPM = 0.0, lastPhaseErr = 0.0, lastAction = ""
    }

    public static let sr = 22050.0
    private let windowSec = 12.0
    private let every = 1.5
    private var ring: [Float]
    private var write = 0, filled = 0
    private var resampPos = 0.0                         // fractional read position in the input stream
    private var lastIn: Float = 0
    private var lastSent = -100.0
    private var inFlight = false
    private let proc = Process()
    private let inPipe = Pipe(), outPipe = Pipe()
    private let lock = NSLock()
    private var pending: [Report] = []
    private var lineBuf = Data()
    public let synchronous: Bool
    private var bigPhaseVotes: [Double] = []
    private var tempoVotes: [Double] = []
    private var lastReportTime = -100.0
    private var lastFix = -100.0
    private var everFresh = false
    public private(set) var status = Status()

    static let logEnabled = ProcessInfo.processInfo.environment["RAVE_REFLOG"] != nil
    static let gate = Double(ProcessInfo.processInfo.environment["RAVE_REFGATE"] ?? "") ?? 0.08
    static let minFillSec = Double(ProcessInfo.processInfo.environment["RAVE_REFMIN"] ?? "") ?? 4
    /// Soft referee phase corrections only above this fraction of a beat: Beat This! beat times are quantised to 20 ms
    /// (+- 10 ms), so correcting smaller errors injects jitter; our own onset tracking is finer. Big flips are separate (0.2).
    static let phaseDead = Double(ProcessInfo.processInfo.environment["RAVE_PHDEAD"] ?? "") ?? 0.1
    /// Where the optional referee lives, resolved at run time (no build-time paths are baked into the binary).
    /// Order: `RAVE_REFEREE_DIR`; a `tools/` folder next to the checkout above the executable (works for
    /// `.build/release/...` and for `build/RAVE LIVE.app`); `~/Library/Application Support/RAVE LIVE/tools`.
    /// If nothing is found the app runs without the referee.
    public static func locateToolsDir(env: [String: String], executable: URL?, home: String,
                                      exists: (String) -> Bool) -> String {
        if let d = env["RAVE_REFEREE_DIR"], !d.isEmpty { return NSString(string: d).expandingTildeInPath }
        var dir = executable?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir, d.path != "/" else { break }
            if exists(d.appendingPathComponent("tools/referee.py").path) { return d.appendingPathComponent("tools").path }
            dir = d.deletingLastPathComponent()
        }
        return home + "/Library/Application Support/RAVE LIVE/tools"
    }
    public static var toolsDir: String {
        locateToolsDir(env: ProcessInfo.processInfo.environment, executable: Bundle.main.executableURL,
                       home: NSHomeDirectory(), exists: { FileManager.default.fileExists(atPath: $0) })
    }
    public static var defaultPython: String {
        ProcessInfo.processInfo.environment["RAVE_REFEREE_PYTHON"] ?? (toolsDir as NSString).appendingPathComponent(".venv/bin/python")
    }
    public static var defaultScript: String {
        ProcessInfo.processInfo.environment["RAVE_REFEREE_SCRIPT"] ?? (toolsDir as NSString).appendingPathComponent("referee.py")
    }

    public init?(python: String = BeatReferee.defaultPython, script: String = BeatReferee.defaultScript, synchronous: Bool = false, startupTimeout: TimeInterval = 60) {
        guard FileManager.default.isExecutableFile(atPath: python), FileManager.default.fileExists(atPath: script) else { return nil }
        signal(SIGPIPE, SIG_IGN)   // a dead sidecar must surface as a failed write, not kill the app
        self.synchronous = synchronous
        ring = [Float](repeating: 0, count: Int(windowSec * Self.sr))
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script]
        proc.standardInput = inPipe; proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // Wait for {"ready": true}, but never longer than startupTimeout: a hung or silent sidecar must not
        // freeze the app. The read runs on a helper thread so the deadline is enforced even if it blocks.
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while let l = readLine() { if l.contains("ready") { ready.signal(); return } }
        }
        guard ready.wait(timeout: .now() + startupTimeout) == .success, proc.isRunning else {
            proc.terminate()
            return nil
        }
        status.running = proc.isRunning
        if !synchronous {
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                guard let self else { return }
                let d = h.availableData
                if d.isEmpty { return }
                self.lock.lock(); self.lineBuf.append(d)
                while let nl = self.lineBuf.firstIndex(of: 0x0A) {
                    let line = self.lineBuf[self.lineBuf.startIndex..<nl]; self.lineBuf.removeSubrange(self.lineBuf.startIndex...nl)
                    if let r = Self.parse(Data(line)) { self.pending.append(r) }
                    self.inFlight = false
                }
                self.lock.unlock()
            }
        }
    }
    /// Write to the sidecar without raising if it has died (legacy `write(_:)` throws an uncatchable NSException).
    func send(_ data: Data) -> Bool {
        do { try inPipe.fileHandleForWriting.write(contentsOf: data); return true } catch { return false }
    }
    deinit { stop() }
    public func stop() { if proc.isRunning { proc.terminate() } }

    private func readLine() -> String? {
        var d = Data()
        while true {
            let b = outPipe.fileHandleForReading.readData(ofLength: 1)
            if b.isEmpty { return d.isEmpty ? nil : String(data: d, encoding: .utf8) }
            if b[0] == 0x0A { return String(data: d, encoding: .utf8) }
            d.append(b)
        }
    }
    private static func parse(_ d: Data) -> Report? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["t_end"] as? Double,
              let b = o["beats"] as? [Double], let dn = o["downbeats"] as? [Double] else { return nil }
        return Report(tEnd: t, beats: b, downbeats: dn, ms: o["ms"] as? Double ?? 0)
    }

    /// Feed the same samples the analyzer gets (any rate); call `step` after.
    public func feed(_ x: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let ratio = sampleRate / Self.sr
        for v in x {
            // linear-interp decimation to 22.05 kHz (a 2-tap box pre-filter is enough for beat tracking)
            while resampPos <= 1 {
                let s = lastIn + Float(resampPos) * (v - lastIn)
                ring[write] = s; write = (write + 1) % ring.count; filled = min(ring.count, filled + 1)
                resampPos += ratio
            }
            resampPos -= 1
            lastIn = v
        }
    }

    /// Send a window when due, apply any finished reports. Call on the analysis thread.
    public func step(_ a: LiveAnalyzer) {
        let now = a.streamTime
        if now - lastSent >= every && filled >= Int(Self.minFillSec * Self.sr) && proc.isRunning {
            lock.lock(); let busy = inFlight; lock.unlock()
            if !busy {
                lastSent = now
                var out = Data(capacity: 12 + filled * 4)
                var n = UInt32(filled), t = now
                withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
                let start = (write - filled + ring.count) % ring.count
                var chunk = [Float](repeating: 0, count: filled)
                for i in 0..<filled { chunk[i] = ring[(start + i) % ring.count] }
                chunk.withUnsafeBytes { out.append(contentsOf: $0) }
                lock.lock(); inFlight = true; lock.unlock()
                if !send(out) { lock.lock(); inFlight = false; lock.unlock() }
                if synchronous, let l = readLine(), let r = Self.parse(Data(l.utf8)) {
                    lock.lock(); pending.append(r); inFlight = false; lock.unlock()
                }
            }
        }
        lock.lock(); let rs = pending; pending.removeAll(); lock.unlock()
        for r in rs { apply(r, a) }
        // stale referee (silence / process died): drop the prior so the causal tracker is free again
        let fresh = now - lastReportTime <= 8
        if !fresh { a.tempo.setReferee(bpm: nil); a.bar.setReferee(offset: nil) }
        // Measured (12 tracks vs Beat This! ground truth): with the referee, broadband phase is best
        // (F 0.82 vs 0.80 at kick weight 0.4); without it, kick-weighted phase is best (0.60 vs 0.46).
        if ProcessInfo.processInfo.environment["RAVE_LOWW"] == nil {
            if fresh { everFresh = true }
            // fresh: broadband phase (referee owns coarse phase). Stale after having been fresh: fully causal, so use the
            // strongly kick-weighted phase. Warm-up (sidecar loaded but no report yet): keep the legacy mild mix, because
            // the first referee corrections are learned against it (measured: switching mix at the first report cost
            // 0.01 F / 1.6-2.9 ms |offset| in referee mode).
            a.tempo.setLowPhaseWeight(fresh ? 0 : everFresh ? TempoTracker.causalLowWeight : 1)
        }
    }

    /// RMS residual of beat times about their least-squares grid (time = a + b * index), as a fraction of `period`.
    /// ~0.01-0.05 for a real groove, 0.4-1.2 for the scattered "beats" Beat This! returns on sparse intros/breakdowns.
    /// Returns .infinity for fewer than 3 beats or a non-positive period (cannot judge -> treat as irregular).
    public static func gridResidual(_ beats: [Double], period: Double) -> Double {
        guard beats.count >= 3, period > 0, period.isFinite else { return .infinity }
        let n = Double(beats.count)
        let xs: [Double] = (0..<beats.count).map(Double.init)
        let mx: Double = xs.reduce(0, +) / n
        let my: Double = beats.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for (x, y) in zip(xs, beats) { sxx += (x - mx) * (x - mx); sxy += (x - mx) * (y - my) }
        let slope = sxy / sxx
        let icpt = my - slope * mx
        var sse = 0.0
        for (x, y) in zip(xs, beats) { let r = y - (icpt + slope * x); sse += r * r }
        return (sse / n).squareRoot() / period
    }

    private func apply(_ r: Report, _ a: LiveAnalyzer) {
        status.reports += 1; status.lastMs = r.ms
        let prevReport = lastReportTime; lastReportTime = a.streamTime
        let lo = r.tEnd - windowSec + 1.5, hi = r.tEnd - 1.0           // trust the middle of the window
        let rb = r.beats.filter { $0 >= lo && $0 <= hi }
        guard rb.count >= 4 else { return }
        let ibis = zip(rb.dropFirst(), rb).map { $0 - $1 }.sorted()
        let ibi = ibis[ibis.count / 2]
        guard ibi > 0.25, ibi < 1.0 else { return }
        // least-squares tempo over the region (Beat This! quantises to 20 ms frames; the fit removes that)
        let n = Double(rb.count), xs = (0..<rb.count).map(Double.init)
        let mx = xs.reduce(0, +) / n, my = rb.reduce(0, +) / n
        let slope = zip(xs, rb).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        let refBPM = 60 / (abs(slope - ibi) < 0.03 ? slope : ibi)
        // regularity: rms residual of the beat times about the fitted grid, as a fraction of the beat period
        let rms = Self.gridResidual(rb, period: ibi)
        if Self.logEnabled { print(String(format: "REFLOG resid=%.3f", rms)) }
        // Sparse intros / breakdowns make Beat This! return scattered, irregular "beats" (resid 0.4-1.2 of a beat vs
        // < 0.06 on a real groove). Acting on them hijacked the tempo prior (139 -> 188 -> 140 -> 170 ...) and the phase.
        if Self.gate > 0, rms > Self.gate { lastReportTime = prevReport; status.rejected += 1; return }
        status.refBPM = refBPM
        a.tempo.setReferee(bpm: refBPM)
        let ours = a.tempo.outputBPM
        if Self.logEnabled { print(String(format: "REFLOG t=%.1f ref=%.2f ours=%.2f fly=%d nbeats=%d", a.streamTime, refBPM, ours, a.tempo.flywheel ? 1 : 0, rb.count)) }
        guard ours > 0 else { return }
        // 1) tempo level: two reports in a row disagreeing by > 3% -> adopt the referee's tempo
        if abs(ours / refBPM - 1) > 0.03 {
            tempoVotes.append(refBPM)
            if tempoVotes.count >= 2, abs(tempoVotes[tempoVotes.count - 2] / refBPM - 1) < 0.03 {
                a.tempo.adopt(bpm: refBPM); status.tempoFixes += 1; tempoVotes.removeAll(); lastFix = a.streamTime
                status.lastAction = String(format: "tempo %.1f→%.1f", ours, refBPM)
            }
            return
        }
        tempoVotes.removeAll()
        // 2) phase: circular mean offset of our beats vs the referee's, as a fraction of a beat
        let period = 60 / ours
        // only judge beats placed *after* our last correction (older ones would make us correct twice)
        let mine = a.beatHistory.filter { $0.time >= max(lo, lastFix + 0.3) && $0.time <= hi }
        let mineAll = a.beatHistory.filter { $0.time >= lo && $0.time <= hi }
        guard mine.count >= 4 else { barVote(r, mineAll, lo: lo, hi: hi, period: period, a: a); return }
        var sx = 0.0, sy = 0.0
        for b in mine {
            guard let near = rb.min(by: { abs($0 - b.time) < abs($1 - b.time) }) else { continue }
            var f = (b.time - near) / period; f -= f.rounded()
            sx += cos(2 * .pi * f); sy += sin(2 * .pi * f)
        }
        let phi = atan2(sy, sx) / (2 * .pi)                               // + = we are late
        status.lastPhaseErr = phi * period * 1000
        if Self.logEnabled { print(String(format: "REFLOG   phaseErr=%.0fms (mine=%d)", phi * period * 1000, mine.count)) }
        let pf = a.tempo.periodFramesNow
        if a.tempo.flywheel { return }          // breakdown: hold the grid, judge again when the kick is back
        if abs(phi) > 0.2 {
            bigPhaseVotes.append(phi)
            if bigPhaseVotes.count >= 2, abs(bigPhaseVotes[bigPhaseVotes.count - 2] - phi) < 0.12 {
                a.tempo.correctPhase(byFrames: -phi * pf, hard: true); status.phaseFixes += 1; bigPhaseVotes.removeAll(); lastFix = a.streamTime
                status.lastAction = String(format: "phase flip %.0f ms", -phi * period * 1000)
            }
        } else {
            bigPhaseVotes.removeAll()
            if abs(phi) > Self.phaseDead { a.tempo.correctPhase(byFrames: -0.6 * phi * pf, hard: false); lastFix = a.streamTime }
        }
        barVote(r, mineAll, lo: lo, hi: hi, period: period, a: a)
    }

    private func barVote(_ r: Report, _ mine: [(index: Int, time: Double)], lo: Double, hi: Double, period: Double, a: LiveAnalyzer) {
        // 3) bar line: which of our beat indices (mod 4) sit on the referee's downbeats
        var votes = [0, 0, 0, 0]
        for d in r.downbeats where d >= lo && d <= hi {
            if let b = mine.min(by: { abs($0.time - d) < abs($1.time - d) }), abs(b.time - d) < 0.25 * period {
                votes[((b.index % 4) + 4) % 4] += 1
            }
        }
        let total = votes.reduce(0, +)
        if total >= 2, let best = votes.indices.max(by: { votes[$0] < votes[$1] }), Double(votes[best]) >= 0.6 * Double(total) {
            if a.bar.refereeOffset != best { status.barFixes += 1 }
            a.bar.setReferee(offset: best)
        }
    }
}
