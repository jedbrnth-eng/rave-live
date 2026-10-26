// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// Light-show director: picks looks on phrase boundaries, sequences build-ups and drops,
/// and fires pyro. Pure logic (no Metal) so it is unit-testable.
final class ShowDirector {
    struct Input {
        var now: Double
        var dt: Float
        var energy: Float
        var energyShort: Float
        var energyLong: Float
        var kick: Bool          // new kick onset this frame
        var snare: Bool         // new snare onset this frame
        var beatIndex: Int      // predicted beat counter
        var beatLocked: Bool
        var playing: Bool
    }
    struct Output {
        var look: Float = 0, beamProg: Float = 0, laserProg: Float = 0
        var laser: Float = 0, fire: Float = 0, jetMask: Float = 15, fireball: Float = 1
        var sparks: Float = 0, co2: Float = 0, blinder: Float = 0, build: Float = 0
        var drop: Float = 0, smoke: Float = 0
        var flashRequest = false   // blinder hit: must pass the strobe limiter
    }

    private(set) var out = Output()
    private var rng: UInt64 = 0x9E3779B97F4A7C15
    private var lastPhrase = -1
    private var phraseStartTime = 0.0
    private var snareTimes: [Double] = []
    private var lastKickTime = 0.0
    private var buildScore: Float = 0
    /// Recent peak of the build score (falls 0.25/s): the drop check uses it, so the gap right before a drop (where the
    /// score itself decays) doesn't cancel the drop. On the demo only the first drop of the session used to be detected.
    private var buildPeak: Float = 0
    private var lowSince = 0.0
    private(set) var dropTime = -100.0
    private var dropBeat = -1000
    private var lastHypeBeat = -1000
    private var fireballStart = -100.0
    private var playingSince = 0.0
    private(set) var events: [(Double, String)] = []

    private func rand(_ n: Int) -> Int {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Int(rng % UInt64(n))
    }

    func step(_ i: Input) -> Output {
        let now = i.now, dt = i.dt
        if !i.playing { playingSince = now } else if playingSince == 0 { playingSince = now }
        if i.snare { snareTimes.append(now) }
        snareTimes.removeAll { now - $0 > 8 }
        let gapSinceKick = now - lastKickTime
        if i.kick { lastKickTime = now }

        // ---- phrase boundaries: every 16 beats when locked, else every 8 s
        let phrase = i.beatLocked ? i.beatIndex / 16 : Int(now / 8)
        if phrase != lastPhrase && i.playing {
            lastPhrase = phrase
            phraseStartTime = now
            pickLooks(energy: i.energy)
            // hype moment for music without EDM drops (rap, rock): fire on a loud phrase start
            if i.beatLocked && now - playingSince > 8 && i.energy > 0.72 && i.beatIndex - lastHypeBeat >= 32 && i.beatIndex - dropBeat > 16 {
                lastHypeBeat = i.beatIndex
                out.fire = 1; out.jetMask = rand(2) == 0 ? 9 : 6; out.sparks = max(out.sparks, 0.8)
                events.append((now, "hype"))
            }
        }

        // ---- build-up: snare density rising while the kick drops out or energy climbs
        let snRecent = Float(snareTimes.filter { now - $0 < 2 }.count) / 2
        let snOld = Float(snareTimes.filter { now - $0 >= 2 }.count) / 6
        let ratio = i.energyShort / max(1e-5, i.energyLong)
        let rising = snRecent > max(2.5, snOld * 1.6) || (snRecent > 3 && gapSinceKick > 1.0)
        buildScore += (rising ? 1 : -1.5) * dt * 0.5
        buildScore = min(1, max(0, buildScore))
        buildPeak = max(buildScore, buildPeak - dt * 0.25)

        // ---- drop: (a) energy returns after a breakdown, or (b) a kick lands after a build + gap
        if ratio < 0.6 { if lowSince == 0 { lowSince = now } } else if ratio > 0.9 {
            if lowSince > 0 && now - lowSince > 2 && ratio > 1.15 && now - playingSince > 8 { triggerDrop(i, "drop(breakdown)") }   // not the song simply starting
            lowSince = 0
        }
        if i.kick && buildPeak > 0.35 && gapSinceKick > 0.4 && now - dropTime > 8 { triggerDrop(i, "drop(build)") }
        out.build = buildScore

        // ---- after a drop: jets on kicks for 8 beats, sparks 16 beats
        let sinceDropBeats = i.beatIndex - dropBeat
        if i.kick && sinceDropBeats >= 0 && sinceDropBeats < 8 {
            out.fire = 1; out.jetMask = (sinceDropBeats % 2 == 0) ? 9 : 6
        }
        out.fire *= expf(-dt * 2.2)
        if sinceDropBeats >= 0 && sinceDropBeats < 8 { out.fire = max(out.fire, 0.7) }   // sustained jets through the drop
        out.sparks = sinceDropBeats >= 0 && sinceDropBeats < 16 ? 1 : out.sparks * expf(-dt * 1.2)
        out.co2 *= expf(-dt * 0.8)   // ~2.5 s burst
        out.fireball = Float(min(1, (now - fireballStart) / 1.6))
        out.smoke = max(out.smoke * expf(-dt * 0.15), out.fire * 0.8)
        out.drop *= expf(-dt * 0.35)

        // ---- blinders ramp during the build, hit on the drop
        out.blinder = max(buildScore * buildScore * 0.5, out.blinder * expf(-dt * 4))

        // ---- lasers: on with energy / after a drop
        let laserOn: Float = (i.energy > 0.7 || out.drop > 0.3) ? 1 : 0
        out.laser += (laserOn - out.laser) * min(1, dt * 3)
        if !i.playing { out.laser *= expf(-dt * 2) }
        return out
    }

    private func triggerDrop(_ i: Input, _ why: String) {
        dropTime = i.now; dropBeat = i.beatIndex
        out.drop = 1; out.co2 = 1; out.fire = 1; out.jetMask = 15
        fireballStart = i.now
        out.blinder = 1; out.flashRequest = true
        buildScore = 0; buildPeak = 0
        // drop look: strongest laser + beam programs
        out.laserProg = Float([0, 2, 3][rand(3)]); out.beamProg = Float([1, 3][rand(2)])
        events.append((i.now, why))
    }

    private func pickLooks(energy: Float) {
        // calm music gets calmer programs; loud gets the aggressive ones
        let calm = energy < 0.45
        var look = Float(rand(6)); if look == out.look { look = Float((Int(look) + 1) % 6) }
        out.look = look
        out.beamProg = calm ? Float([0, 4][rand(2)]) : Float(rand(5))
        out.laserProg = Float(rand(5))
    }

    /// Consume the one-shot flash request (caller routes it through the strobe limiter).
    func takeFlash() -> Bool { let f = out.flashRequest; out.flashRequest = false; return f }
}
