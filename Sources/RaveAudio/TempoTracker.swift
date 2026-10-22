import Accelerate
import Foundation

/// Rolling-window tempo + beat-phase tracker.
///
/// Every `updateEvery` frames it autocorrelates the last `windowSeconds` of the
/// onset envelope, scores candidate tempi with a 4-harmonic comb, applies a mild
/// log-tempo prior, and runs a hysteresis switch so DJ transitions re-lock fast
/// while octave flips are suppressed. A phase-locked beat clock predicts the next
/// beat so effects can fire on it instead of after it.
public final class TempoTracker {
    public let fps: Double
    public let windowSeconds: Double
    public var minBPM: Double = 70
    public var maxBPM: Double = 200
    public var priorCenter: Double = 120
    public var priorOctaves: Double = 0.7
    public var subdivisionRatio: Double = 0.6
    var lastSubdivision = 0.0
    let debugTruth: Double? = ProcessInfo.processInfo.environment["RAVE_TRUTH"].flatMap(Double.init)
    static let phLog = ProcessInfo.processInfo.environment["RAVE_PHLOG"] != nil
    static let phaseRefine = Int(ProcessInfo.processInfo.environment["RAVE_REFINE"] ?? "") ?? 3
    /// Kick-band weight for the causal-only phase (referee-less); the referee path sets 0.
    public static let causalLowWeight: Float = 16

    public private(set) var bpm: Double = 0
    public private(set) var confidence: Double = 0
    /// Manual nudge in BPM, added on top of the tracked value.
    public var nudge: Double = 0
    /// Manual override (tap tempo). When set, tracking still runs but output is pinned.
    public var manualBPM: Double?

    private var env: [Float]
    private var envLow: [Float]
    /// Weight of the kick-band onset in beat *phase* (not tempo). House/tech-house put loud open hats on the
    /// off-beat; broadband flux alone locks there (measured against Beat This!: 3 of 12 tracks on the off-beat).
    public var lowPhaseWeight: Float = Float(ProcessInfo.processInfo.environment["RAVE_LOWW"] ?? "") ?? TempoTracker.causalLowWeight
    /// Referee (Beat This!) corrections: tempo level prior and a phase bias in frames.
    public private(set) var refereeBPM: Double?
    public private(set) var phaseBias: Double = 0
    public private(set) var flywheel = false
    public var flywheelEnabled = ProcessInfo.processInfo.environment["RAVE_NOFLY"] == nil
    private var lowShort: Float = 0, lowLong: Float = 0
    public var onHardSwitch: (() -> Void)?
    private var writePos = 0
    private var count = 0
    private let updateEvery: Int
    private var sinceUpdate = 0
    private var candidate: Double = 0
    private var candidateHits = 0
    private var lockAge = 0
    private var framesToNextBeat: Double = 0
    private var periodFrames: Double = 0
    private var lastFrame = 0
    private var taps: [Double] = []

    public init(fps: Double, windowSeconds: Double = 8, updateSeconds: Double = 0.25) {
        self.fps = fps
        self.windowSeconds = windowSeconds
        env = [Float](repeating: 0, count: Int(fps * windowSeconds))
        envLow = [Float](repeating: 0, count: Int(fps * windowSeconds))
        updateEvery = max(1, Int(fps * updateSeconds))
    }

    public var outputBPM: Double { (manualBPM ?? bpm) + nudge }
    public var periodFramesNow: Double { outputBPM > 0 ? 60 / outputBPM * fps : 0 }

    /// Referee: prefer this tempo level from now on (nil clears).
    /// Switching the phase-signal mix changes where the measured beat lands, so the referee-learned bias no longer applies.
    public func setLowPhaseWeight(_ w: Float) { if w != lowPhaseWeight { lowPhaseWeight = w; if Self.resetBiasOnMix { phaseBias = 0 } } }
    static let resetBiasOnMix = ProcessInfo.processInfo.environment["RAVE_NORESETBIAS"] == nil
    public func setReferee(bpm: Double?) { refereeBPM = bpm }
    /// Referee says our metrical level is wrong: jump straight to its tempo (phase is fixed by the next report).
    public func adopt(bpm b: Double) {
        guard manualBPM == nil, b >= minBPM, b <= maxBPM else { return }
        bpm = b; candidate = b; candidateHits = 0; lockAge = 0; phaseBias = 0
        let p = 60 / b * fps
        framesToNextBeat = framesToNextBeat.truncatingRemainder(dividingBy: p); if framesToNextBeat <= 0 { framesToNextBeat += p }
    }
    /// Referee phase correction in frames (+ = beats later). Hard = also move the running clock now.
    public func correctPhase(byFrames f: Double, hard: Bool) {
        let p = periodFramesNow; guard p > 0 else { return }
        phaseBias = (phaseBias + f).truncatingRemainder(dividingBy: p)
        if phaseBias > p / 2 { phaseBias -= p }; if phaseBias < -p / 2 { phaseBias += p }
        if hard {
            framesToNextBeat += f
            while framesToNextBeat <= 0 { framesToNextBeat += p }
            while framesToNextBeat > p { framesToNextBeat -= p }
        }
    }

    public func reset() {
        env = [Float](repeating: 0, count: env.count); envLow = [Float](repeating: 0, count: env.count)
        count = 0; writePos = 0; bpm = 0; confidence = 0; candidate = 0; candidateHits = 0; periodFrames = 0
    }

    /// Tap tempo: call with wall/stream time of each tap. Returns the tapped BPM once 4 taps exist.
    @discardableResult
    public func tap(at time: Double) -> Double? {
        if let last = taps.last, time - last > 2.0 { taps.removeAll() }
        taps.append(time)
        if taps.count > 8 { taps.removeFirst() }
        guard taps.count >= 4 else { return nil }
        let intervals = zip(taps.dropFirst(), taps).map { $0 - $1 }
        let b = 60.0 / (intervals.reduce(0, +) / Double(intervals.count))
        manualBPM = b
        framesToNextBeat = 60.0 / b * fps  // phase resets on the tap
        return b
    }

    struct Beat { var phase: Double; var isBeat: Bool; var framesToNext: Double }

    func push(onset: Float, low: Float = 0, kickHit: Bool = false, frame: Int) -> Beat {
        env[writePos] = onset
        envLow[writePos] = low
        writePos = (writePos + 1) % env.count
        count += 1
        lastFrame = frame
        sinceUpdate += 1
        // Flywheel: in EDM breakdowns/builds the kick disappears and the remaining onsets (pads, risers,
        // snare rolls) pull the phase off the grid. While the kick band is near-silent compared with the
        // last ~8 s, keep the established tempo and phase running untouched (the referee can still correct).
        let k: Float = kickHit ? 1 : 0
        lowShort += (k - lowShort) * Float(1 / (fps * 1.5))
        lowLong += (k - lowLong) * Float(1 / (fps * 8))
        flywheel = flywheelEnabled && bpm > 0 && lowLong * Float(fps) > 0.6 && lowShort < 0.25 * lowLong
        if sinceUpdate >= updateEvery, count >= Int(fps * 2.0) {
            sinceUpdate = 0
            if !flywheel { update() }
        }
        // Advance the beat clock.
        let p = outputBPM > 0 ? 60.0 / outputBPM * fps : 0
        guard p > 0 else { return Beat(phase: 0, isBeat: false, framesToNext: 0) }
        framesToNextBeat -= 1
        var isBeat = false
        if framesToNextBeat <= 0 {
            isBeat = true
            framesToNextBeat += p
            if framesToNextBeat <= 0 { framesToNextBeat = p }
        }
        return Beat(phase: 1 - framesToNextBeat / p, isBeat: isBeat, framesToNext: framesToNextBeat)
    }

    /// Chronological copy of the window, mean-removed and half-wave rectified.
    private func window(lastFrames n: Int, low: Bool = false) -> [Float] {
        let env = low ? self.envLow : self.env
        let n = min(n, min(count, env.count))
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = env[(writePos - n + i + env.count) % env.count] }
        // Remove local trend (moving average ~0.2 s) so sustained energy doesn't dominate.
        let w = max(3, Int(fps * 0.2))
        var out = [Float](repeating: 0, count: n)
        var acc: Float = 0
        for i in 0..<n {
            acc += x[i]
            if i >= w { acc -= x[i - w] }
            let m = acc / Float(min(i + 1, w))
            out[i] = max(0, x[i] - m)
        }
        // Light Gaussian blur (sigma ≈ 1.5 frames) widens peaks so sub-frame lag interpolation is accurate
        // and tolerates human timing jitter.
        let g: [Float] = [0.0276, 0.0663, 0.1238, 0.1802, 0.2042, 0.1802, 0.1238, 0.0663, 0.0276]
        var sm = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var a: Float = 0
            for (j, w) in g.enumerated() { let k = i + j - 4; if k >= 0 && k < n { a += w * out[k] } }
            sm[i] = a
        }
        return sm
    }

    private func update() {
        let x = window(lastFrames: env.count)
        let n = x.count
        let maxLag = min(n - 1, Int(fps * 60.0 / minBPM * 4) + 2)
        guard maxLag > 8 else { return }
        // Unbiased autocorrelation; octave choice is left to the prior + subdivision check.
        var ac = [Float](repeating: 0, count: maxLag + 1)
        x.withUnsafeBufferPointer { p in
            for l in 0...maxLag {
                var s: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + l, 1, &s, vDSP_Length(n - l))
                ac[l] = s / Float(n - l)
            }
        }
        let usable = Double(n) * 0.66
        guard ac[0] > 1e-9 else { confidence = 0; return }
        func acAt(_ lag: Double) -> Double {
            // Catmull-Rom cubic interpolation between integer lags.
            guard lag.isFinite, lag >= 1, lag + 2 <= Double(maxLag) else { return 0 }
            let i = Int(lag)
            let t = lag - Double(i)
            let p0 = Double(ac[i - 1]), p1 = Double(ac[i]), p2 = Double(ac[i + 1]), p3 = Double(ac[i + 2])
            let v = p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
            return v / Double(ac[0])
        }
        func score(_ b: Double) -> Double {
            let lag = fps * 60.0 / b
            var s = 0.0, m = 0.0
            for k in 1...4 where lag * Double(k) <= usable || k == 1 { s += acAt(lag * Double(k)); m += 1 }
            s /= m
            // Penalise tempi whose half-beat is strong but whose beat isn't (catches double-time errors softly).
            let prior = refereeBPM.map { exp(-0.5 * pow(log2(b / $0) / 0.12, 2)) } ?? exp(-0.5 * pow(log2(b / priorCenter) / priorOctaves, 2))
            return s * prior
        }
        var best = 0.0, bestB = 0.0, sum = 0.0, cnt = 0.0
        var b = minBPM
        while b <= maxBPM {
            let s = score(b)
            sum += s; cnt += 1
            if s > best { best = s; bestB = b }
            b += 0.5
        }
        // Fine search ±0.6 BPM.
        var fb = bestB - 0.6
        while fb <= bestB + 0.6 {
            let s = score(fb)
            if s > best { best = s; bestB = fb }
            fb += 0.02
        }
        // No periodic structure at all (e.g. one isolated hit): nothing to lock to.
        guard best > 0, bestB > 0 else { confidence *= 0.6; return }
        // Subdivision check: a slow winner whose quarter-beat is strongly periodic
        // (16ths at the slow tempo, e.g. DnB read as 87) is really double time.
        if bestB * 2 <= maxBPM {
            let lag = fps * 60.0 / bestB
            let q = acAt(lag / 4), h = acAt(lag / 2)
            if h > 0, q / h > subdivisionRatio {
                // Only accept the doubling if double time is itself a strong periodicity
                // (otherwise this is a triplet/shuffle feel, not double time).
                let d = score(bestB * 2)
                if d >= 0.6 * best { bestB *= 2; best = d }
            }
        }
        lastSubdivision = bestB
        if let tr = debugTruth {
            let cands = [tr, tr * 2, tr / 2, tr * 1.5, tr * 2 / 3, tr * 4 / 3, tr * 0.75].filter { $0 >= minBPM && $0 <= maxBPM }
            print(String(format: "dbg t=%.2f best=%.2f s=%.3f | ", Double(count) / fps, bestB, best) + cands.map { String(format: "%.1f:%.3f", $0, score($0)) }.joined(separator: " "))
        }
        let mean = sum / max(1, cnt)
        let conf = best > 0 ? max(0, min(1, (best - mean) / best * 1.4)) : 0
        confidence = 0.6 * confidence + 0.4 * conf
        guard conf > 0.15 else { return }

        // Hysteresis switch.
        lockAge += 1
        if bpm == 0 {
            // Before first lock, octave-related estimates count as agreeing (flip-flop 80/160 must not stall lock);
            // a later octave correction still goes through the stricter switch below.
            let r = bestB / max(1, candidate)
            let same = abs(r - 1) < 0.02 || abs(r - 2) < 0.04 || abs(r - 0.5) < 0.02
            if same { candidateHits += 1; candidate = bestB } else { candidate = bestB; candidateHits = 1 }
            if candidateHits >= 3 { bpm = bestB; candidateHits = 0; lockAge = 0; resyncPhase(x: x, hard: true) }
        } else if abs(bestB - bpm) / bpm < 0.03 {
            bpm += 0.35 * (bestB - bpm)
            candidateHits = 0
            resyncPhase(x: x, hard: false)
        } else {
            // Locked and the window prefers another tempo. Sparse sections (vocal breaks, intros, triplet feels)
            // often prefer a 3:2 / 4:3 relative of the real beat, so be sticky:
            //  - keep refining the current tempo locally,
            //  - switch only if the challenger beats the current tempo's own score by a clear margin
            //    for long enough (octave: 2 s, metric ratios: 3 s, unrelated tempo e.g. DJ transition: 1.5 s).
            var cur = score(bpm), curB = bpm
            var lb = bpm * 0.985
            while lb <= bpm * 1.015 { let sc = score(lb); if sc > cur { cur = sc; curB = lb }; lb += 0.05 }
            let margin = best / max(cur, 1e-9)
            let ratio = bestB / bpm
            func near(_ r: Double) -> Bool { abs(ratio - r) / r < 0.03 }
            let octave = near(2) || near(0.5)
            let metric = near(1.5) || near(2.0 / 3) || near(4.0 / 3) || near(0.75)
            // A fresh lock (< 8 s old) is provisional: let a better tempo take over quickly.
            let provisional = lockAge < Int(8 * fps / Double(updateEvery))
            let need = provisional ? 3 : octave ? 8 : metric ? 12 : 4
            let minMargin = provisional ? 1.05 : octave ? 1.1 : metric ? 1.25 : 1.1
            if margin >= minMargin {
                if abs(bestB - candidate) / max(1, candidate) < 0.02 { candidateHits += 1 } else { candidate = bestB; candidateHits = 1 }
            } else {
                candidateHits = max(0, candidateHits - 1)
            }
            if candidateHits >= need {
                bpm = bestB; candidateHits = 0; lockAge = provisional ? lockAge : 0; phaseBias = 0; onHardSwitch?(); resyncPhase(x: x, hard: true)
            } else {
                if abs(curB - bpm) / bpm < 0.015 { bpm += 0.2 * (curB - bpm) }
                resyncPhase(x: x, hard: false)
            }
        }
    }

    /// Phase estimation: which offset of a pulse train at the current period best matches recent onsets.
    private func resyncPhase(x: [Float], hard: Bool) {
        guard manualBPM == nil else { return }
        let p = 60.0 / outputBPM * fps
        guard p > 2 else { return }
        // phase signal: broadband onsets + kick-band onsets, each normalised to its own mean
        var x = x
        let xBroad = x
        if lowPhaseWeight > 0 {
            let xl = window(lastFrames: x.count, low: true)
            if xl.count == x.count {
                let mb = max(1e-9, x.reduce(0, +) / Float(x.count)), ml = max(1e-9, xl.reduce(0, +) / Float(xl.count))
                for i in 0..<x.count { x[i] = x[i] / mb + lowPhaseWeight * xl[i] / ml }
            }
        }
        let n = x.count
        let span = min(n, Int(fps * 4))
        var bestPhi = 0, bestS: Float = -1
        func phaseScore(_ sig: [Float], _ phi: Int) -> Float {
            var s: Float = 0
            var t = Double(n - 1 - phi)
            while t >= Double(n - span) {
                let i = Int(t.rounded())
                if i >= 0 && i < n {
                    // small tolerance window
                    s += sig[i] + 0.5 * (i > 0 ? sig[i - 1] : 0) + 0.5 * (i + 1 < n ? sig[i + 1] : 0)
                }
                t -= p
            }
            return s
        }
        for phi in 0..<Int(p) {
            let s = phaseScore(x, phi)
            if s > bestS { bestS = s; bestPhi = phi }
        }
        // The kick-weighted signal picks the right beat (not the off-beat hats) but kick-band flux peaks a little
        // after the broadband transient (measured: +13 ms late vs Beat This!). Keep its choice, then slide up to
        // `phaseRefine` frames to where the broadband onsets are sharpest.
        if lowPhaseWeight >= 4, Self.phaseRefine > 0 {
            var rb = bestPhi, rs: Float = -1
            for d in -Self.phaseRefine...Self.phaseRefine {
                let phi = bestPhi + d; if phi < 0 { continue }
                let s = phaseScore(xBroad, phi)
                if s > rs { rs = s; rb = phi }
            }
            bestPhi = rb
        }
        // Last beat was bestPhi frames ago => next beat in p - bestPhi frames (+ referee bias).
        var measured = p - Double(bestPhi) + phaseBias
        measured = measured.truncatingRemainder(dividingBy: p); if measured <= 0 { measured += p }
        if hard || periodFrames == 0 {
            framesToNextBeat = measured
        } else {
            var err = measured - framesToNextBeat
            if err > p / 2 { err -= p }
            if err < -p / 2 { err += p }
            // With the referee active it owns coarse phase: the causal tracker may only track small drift.
            // Otherwise hats/claps on the off-beat drag it half a beat away between referee reports.
            if refereeBPM != nil && abs(err) > 0.12 * p { err = 0 }
            if TempoTracker.phLog { print(String(format: "PHLOG t=%.2f err/p=%+.3f lowW=%.1f ref=%d fly=%d bias=%.1f", Double(count) / fps, err / p, lowPhaseWeight, refereeBPM != nil ? 1 : 0, flywheel ? 1 : 0, phaseBias)) }
            framesToNextBeat += 0.35 * err
        }
        periodFrames = p
    }
}
