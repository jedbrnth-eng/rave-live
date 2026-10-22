import Foundation

/// Deterministic drum-pattern synthesizer for ground-truth tempo tests.
public enum Synth {
    public struct Pattern: Sendable {
        public var name: String
        public var bpm: Double
        /// Steps per beat = 4 (16ths). Each string is 16 steps (one bar); 'x' = hit.
        public var kick: String
        public var snare: String
        public var hat: String
        public var swing: Double = 0   // fraction of a 16th to delay odd 16ths
        public var pad = true
        public init(name: String, bpm: Double, kick: String, snare: String, hat: String, swing: Double = 0, pad: Bool = true) {
            self.name = name; self.bpm = bpm; self.kick = kick; self.snare = snare; self.hat = hat; self.swing = swing; self.pad = pad
        }
    }

    public static let house = Pattern(name: "house", bpm: 128, kick: "x...x...x...x...", snare: "....x.......x...", hat: "..x...x...x...x.")
    public static let dnb = Pattern(name: "dnb", bpm: 174, kick: "x.........x.....", snare: "....x.......x...", hat: "x.x.x.x.x.x.x.x.")
    public static let boomBap = Pattern(name: "boombap", bpm: 90, kick: "x......x..x.....", snare: "....x.......x...", hat: "x.x.x.x.x.x.x.x.", swing: 0.3)
    public static let rock = Pattern(name: "rock", bpm: 120, kick: "x.......x.x.....", snare: "....x.......x...", hat: "x.x.x.x.x.x.x.x.")
    public static let metal = Pattern(name: "metal", bpm: 160, kick: "xxxxxxxxxxxxxxxx", snare: "....x.......x...", hat: "x...x...x...x...", pad: false)
    public static let techno = Pattern(name: "techno", bpm: 140, kick: "x...x...x...x...", snare: "................", hat: "..x...x...x...x.")

    /// Render `seconds` of mono audio at `sr`. Optional `bpmEnd` ramps tempo linearly (DJ pitch ride).
    public static func render(_ p: Pattern, seconds: Double, sr: Double = 48000, bpmEnd: Double? = nil, seed: UInt64 = 1, noise: Float = 0.01) -> [Float] {
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n)
        var rng = seed
        func rnd() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: rng >> 11) % 2_000_000) / 1_000_000 - 1 }
        // Walk steps with possibly varying tempo.
        var t = 0.0, step = 0
        let k = Array(p.kick), s = Array(p.snare), h = Array(p.hat)
        while t < seconds {
            let frac = t / seconds
            let bpm = p.bpm + ((bpmEnd ?? p.bpm) - p.bpm) * frac
            let stepDur = 60.0 / bpm / 4
            let i = step % 16
            let at = t + (i % 2 == 1 ? p.swing * stepDur : 0)
            let start = Int(at * sr)
            if k[i] == "x" { addKick(&out, start, sr) }
            if s[i] == "x" { addNoiseHit(&out, start, sr, dur: 0.18, amp: 0.5, hp: false, rnd: rnd); addTone(&out, start, sr, f: 190, dur: 0.12, amp: 0.3) }
            if h[i] == "x" { addNoiseHit(&out, start, sr, dur: 0.04, amp: 0.25, hp: true, rnd: rnd) }
            t += stepDur; step += 1
        }
        if p.pad {  // sustained chord so the signal isn't drums-only
            for j in 0..<n {
                let tt = Double(j) / sr
                out[j] += 0.05 * Float(sin(2 * .pi * 220 * tt) + sin(2 * .pi * 277.18 * tt) + sin(2 * .pi * 329.63 * tt))
            }
        }
        for j in 0..<n { out[j] = max(-1, min(1, out[j] * 0.7 + noise * rnd())) }
        return out
    }

    static func addKick(_ o: inout [Float], _ start: Int, _ sr: Double) {
        let len = Int(0.25 * sr); var ph = 0.0
        for j in 0..<len where start + j < o.count {
            let tt = Double(j) / sr
            let f = 50 + 90 * exp(-tt * 30)
            ph += 2 * .pi * f / sr
            o[start + j] += Float(sin(ph) * exp(-tt * 12)) * 0.9
            // beater click: short broadband transient, like a real kick
            if j < Int(0.004 * sr) { o[start + j] += Float(exp(-tt * 900)) * (j % 2 == 0 ? 0.5 : -0.5) }
        }
    }
    static func addTone(_ o: inout [Float], _ start: Int, _ sr: Double, f: Double, dur: Double, amp: Float) {
        let len = Int(dur * sr)
        for j in 0..<len where start + j < o.count {
            let tt = Double(j) / sr
            o[start + j] += amp * Float(sin(2 * .pi * f * tt) * exp(-tt * 25))
        }
    }
    static func addNoiseHit(_ o: inout [Float], _ start: Int, _ sr: Double, dur: Double, amp: Float, hp: Bool, rnd: () -> Float) {
        let len = Int(dur * sr); var prev: Float = 0
        for j in 0..<len where start + j < o.count {
            let tt = Double(j) / sr
            var v = rnd()
            if hp { let d = v - prev; prev = v; v = d * 0.6 }
            o[start + j] += amp * v * Float(exp(-tt * (hp ? 90 : 22)))
        }
    }
}

/// Offline run of the streaming analyzer (same code path as live, fed in 512-sample chunks).
public struct TempoRun {
    public var timeline: [(t: Double, bpm: Double, conf: Double)] = []
    public var beats: [Double] = []
    public var beatInBar: [Int] = []
    public var barConf: [Double] = []
    public var kicks = 0, snares = 0, hats = 0
    public var refereeStatus: BeatReferee.Status?
    public var flywheelTimes: [Double] = []

    public static func run(_ samples: [Float], sr: Double, chunk: Int = 480, referee: BeatReferee? = nil) -> TempoRun {
        let a = LiveAnalyzer(sampleRate: sr)
        var r = TempoRun()
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + chunk)
            let frames = samples[i..<end].withUnsafeBufferPointer { b -> [AnalysisFrame] in
                let f = a.process(b)
                if let r = referee { r.feed(b, sampleRate: sr); r.step(a) }
                return f
            }
            for f in frames {
                r.timeline.append((f.time, f.bpm, f.confidence))
                if a.tempo.flywheel { r.flywheelTimes.append(f.time) }
                if f.isBeat { r.beats.append(f.beatTime); r.beatInBar.append(f.beatInBar); r.barConf.append(f.barConfidence) }
                if f.kick { r.kicks += 1 }; if f.snare { r.snares += 1 }; if f.hat { r.hats += 1 }
            }
            i = end
        }
        r.refereeStatus = referee?.status
        return r
    }

    /// First time after which the estimate stays within `tol` (fraction) of `truth` until the end.
    public func lockTime(truth: Double, tol: Double = 0.02, from: Double = 0) -> Double? {
        var lock: Double?
        for e in timeline where e.t >= from {
            if e.bpm > 0 && abs(e.bpm - truth) / truth <= tol { if lock == nil { lock = e.t } } else { lock = nil }
        }
        return lock.map { $0 - from }
    }

    public var finalBPM: Double { timeline.last?.bpm ?? 0 }
}
