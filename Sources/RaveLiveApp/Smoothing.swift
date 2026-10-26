// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// Eased onset envelope. A hit sets `raw` to 1, which decays with time constant `release`; the output follows `raw`
/// through a one-pole filter with time constant `attack`. So every hit eases in (10-90 % rise ~2.2 x attack) and fades
/// out over ~release instead of switching on and off in one frame. Scaled so a single hit peaks at 1.
/// Pure maths, unit-tested; numbers chosen in docs/SMOOTHNESS.md.
struct Pulse {
    let attack: Float, release: Float
    private let norm: Float
    private(set) var raw: Float = 0
    private(set) var value: Float = 0

    init(attack: Float, release: Float) {
        self.attack = max(attack, 1e-4); self.release = max(release, attack * 1.5)
        let a = Double(self.attack), r = Double(self.release)
        // peak of the attack/release cascade for one hit (closed form)
        let tp = a * r / (r - a) * log(r / a)
        let peak = r / (r - a) * (exp(-tp / r) - exp(-tp / a))
        norm = Float(1 / max(peak, 0.05))
    }

    /// Advance one frame; returns the eased envelope 0...~1.
    mutating func step(_ hit: Bool, dt: Float) -> Float {
        if hit { raw = 1 }
        // sub-step long frames so a stalled frame can't overshoot or skip the attack
        let n = max(1, min(8, Int((dt / 0.008).rounded(.up))))
        let h = dt / Float(n)
        for _ in 0..<n {
            raw *= expf(-h / release)
            value += (raw - value) * (1 - expf(-h / attack))
        }
        return min(1.2, value * norm)
    }
    var current: Float { min(1.2, value * norm) }
}

/// Critically damped follower (no overshoot, no ringing): the exact solution of x'' = w^2 (target - x) - 2 w x',
/// so it stays stable for any frame time. 10-90 % rise ~3.4 / w seconds.
struct Damped {
    var x: Float = 0, v: Float = 0
    mutating func step(_ target: Float, dt: Float, omega w: Float) -> Float {
        let e = x - target
        let k = expf(-w * dt)
        let c = v + w * e
        let ne = (e + c * dt) * k
        v = (v - w * c * dt) * k
        x = target + ne
        return x
    }
}

/// Smoothed copy of the audio snapshot for the renderers: band energies and loudness through critically damped
/// filters, the spectrum with a fast attack and an eased fall. Removes the frame-to-frame jitter of noisy band
/// estimates (the usual cause of off-beat flicker) while keeping every reaction. Decisions (director, drops) keep
/// using the raw snapshot.
struct AudioSmoother {
    private var bands = [Damped](repeating: Damped(), count: 5)
    private var energy = Damped()
    private var spectrum = [Float](repeating: 0, count: 128)
    /// Rise times: bands ~0.11 s, energy ~0.3 s, spectrum attack ~25 ms / release ~140 ms.
    var bandOmega: Float = 30, energyOmega: Float = 11
    var specAttack: Float = 0.025, specRelease: Float = 0.14

    mutating func step(_ s: AudioSnapshot, dt: Float) -> AudioSnapshot {
        var o = s
        for i in 0..<min(5, s.bands.count) { o.bands[i] = max(0, bands[i].step(s.bands[i], dt: dt, omega: bandOmega)) }
        o.energy = max(0, energy.step(s.energy, dt: dt, omega: energyOmega))
        let ka = 1 - expf(-dt / specAttack), kr = 1 - expf(-dt / specRelease)
        let n = min(128, s.spectrum.count)
        for i in 0..<n {
            let t = s.spectrum[i]
            spectrum[i] += (t - spectrum[i]) * (t > spectrum[i] ? ka : kr)
            o.spectrum[i] = spectrum[i]
        }
        return o
    }
}

/// Grid-locked beat pulse from the beat phase: rises over `lead` seconds before the beat (so it peaks ON the beat
/// instead of one frame after it) and decays with time constant `release` afterwards. Continuous in time.
func beatPulse(phase: Double, bpm: Double, lead: Double, release: Double) -> Float {
    let beat = 60 / max(30, bpm)
    let after = phase * beat                 // seconds since the last beat
    let before = (1 - phase) * beat          // seconds to the next beat
    var v = exp(-after / release)
    if before < lead {
        let x = 1 - before / lead            // 0 -> 1 over the lead
        v = max(v, x * x * (3 - 2 * x))
    }
    return Float(v)
}

/// Stable musical beat counter. The analyzer's bar estimate can flip between two hypotheses on four-on-the-floor
/// material (measured on the demo: the counter jumped by +-2..3 beats about every beat), and everything that moves
/// with the beat clock jumped with it. This counter advances by exactly one per beat-phase wrap and adopts a new bar
/// alignment only after the analyzer has agreed on it for `stableBeats` beats in a row, or at once on a drop (hidden
/// by the drop cut). Pure logic, unit-tested.
struct BeatCounter {
    var stableBeats = 8
    private var own: Int?
    private var align = 0, pending = 0, run = 0
    private var lastPhase = 0.0
    /// How many re-alignments were adopted without a drop (for the metrics log).
    private(set) var realigns = 0

    /// `target` = the analyzer's musical beat (bar + phrase aligned), `phase` 0..1 into the current beat.
    /// Returns the stable beat index and whether it moved by anything other than +1 this frame.
    mutating func step(target: Int, phase: Double, adoptNow: Bool) -> (beat: Int, jumped: Bool) {
        guard let o = own else { own = target; lastPhase = phase; return (target, false) }
        let before = o + align
        var wrapped = false
        if phase < lastPhase - 0.5 { own = o + 1; wrapped = true }
        lastPhase = phase
        let cur = own! + align
        let off = target - cur
        if adoptNow {
            align += off; pending = 0; run = 0
        } else if wrapped {
            if off == 0 { run = 0 } else if off == pending { run += 1 } else { pending = off; run = 1 }
            if run >= stableBeats { align += off; run = 0; realigns += 1 }
        }
        let now = own! + align
        return (now, now != before && now != before + 1)
    }
    /// Move the grid by `n` beats (phrase alignment on a drop).
    mutating func shift(_ n: Int) { align += n }
    /// Forget everything (tempo lock lost): the next locked frame starts a fresh count.
    mutating func reset() { own = nil; align = 0; pending = 0; run = 0 }
}
