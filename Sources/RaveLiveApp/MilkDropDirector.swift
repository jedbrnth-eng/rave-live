// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// Beat-locked MilkDrop preset changes: what plain MilkDrop/projectM can't do.
/// - Phrase lines: a soft blend starts exactly on a downbeat that opens a 16-beat phrase, after the preset has held
///   for `holdBeats` (32 by default; 16 when loud on Wild, 64 on Chill). The blend lasts whole bars, so it ends on a bar line too.
/// - Drops: a hard cut on the drop itself.
/// - Never mid-bar while the beat clock is locked. Without a lock (no tempo yet) it falls back to a timer.
/// Pure logic, no GL/Metal, so it is unit-tested.
struct MilkDropDirector {
    enum Action: Equatable { case none, blend, cut }

    var holdBeats = 32
    var phraseBeats = 16
    var unlockedHoldSeconds = 24.0
    /// Locked by the user (L key / browser): no automatic changes at all, drops included.
    var locked = false

    private(set) var lastSwitchBeat: Int?
    private var lastBeat = Int.min
    private var lastSwitchTime = -1.0e9

    /// Hold length for the current intensity (0 chill, 1 normal, 2 wild) and loudness.
    static func hold(intensity: Int, energy: Float) -> Int {
        if intensity == 0 { return 64 }
        return intensity == 2 && energy > 0.6 ? 16 : 32
    }

    /// Call once per frame. `beat` is the renderer's musical beat counter (beat 0 of each bar is a downbeat,
    /// aligned so the last drop opened a phrase); `beatLocked` says whether that counter means anything.
    /// `phase` is how far into `beat` this frame is (0..1): a phrase change only starts on the frame the downbeat begins.
    mutating func step(beat: Int, phase: Double, beatLocked: Bool, dropStarted: Bool, now: Double) -> Action {
        defer { lastBeat = beat }
        if lastSwitchTime < -1.0e8 { lastSwitchTime = now }       // the first preset counts as a switch
        // the renderer re-aligns its counter (bar found, drop opens a phrase): that is not elapsed time, keep the hold intact
        if beatLocked, lastBeat != Int.min, abs(beat - lastBeat) >= 2, let last = lastSwitchBeat { lastSwitchBeat = last + (beat - lastBeat) }
        if locked { return .none }
        if dropStarted {
            lastSwitchBeat = beat; lastSwitchTime = now
            return .cut
        }
        guard beatLocked else {
            if now - lastSwitchTime >= unlockedHoldSeconds { lastSwitchTime = now; lastSwitchBeat = nil; return .blend }
            return .none
        }
        // only on the frame the counter reaches a phrase downbeat (not on every frame of that beat)
        guard beat != lastBeat, Self.mod(beat, phraseBeats) == 0, phase < 0.25 else { return .none }
        if let last = lastSwitchBeat, beat - last < holdBeats, beat >= last { return .none }
        if lastSwitchBeat == nil && now - lastSwitchTime < 4 { return .none }   // just switched while unlocked
        lastSwitchBeat = beat; lastSwitchTime = now
        return .blend
    }

    /// Note a manual change (keys, browser) so the next automatic one waits a full hold.
    mutating func manualSwitch(now: Double) { lastSwitchBeat = lastBeat == Int.min ? nil : lastBeat; lastSwitchTime = now }

    /// Blend length in seconds: `bars` whole bars at the current tempo (2 s when there is no tempo).
    static func blendSeconds(bpm: Double, bars: Int = 2) -> Double {
        bpm > 0 ? Double(bars * 4) * 60 / bpm : 2
    }

    static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
}
