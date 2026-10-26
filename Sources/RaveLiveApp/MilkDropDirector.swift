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
    private var lastSwitchTime = -1.0e9
    /// Own beat counter: +1 on every phase wrap, so it never jumps mid-beat. It adopts the renderer's counter (bar and
    /// phrase alignment) on a drop, or once the renderer has disagreed by the same amount for 8 beats in a row.
    /// (The renderer's bar estimate can flip back and forth by 2 beats on some material; a phrase change must not follow that.)
    private(set) var own: Int?
    private var lastPhase = 0.0
    private var pendingOffset = 0, offsetRun = 0

    /// Hold length for the current intensity (0 chill, 1 normal, 2 wild) and loudness.
    static func hold(intensity: Int, energy: Float) -> Int {
        if intensity == 0 { return 64 }
        return intensity == 2 && energy > 0.6 ? 16 : 32
    }

    /// Call once per frame. `beat` is the renderer's musical beat counter (beat 0 of each bar is a downbeat,
    /// aligned so the last drop opened a phrase), `phase` how far into that beat this frame is (0..1);
    /// `beatLocked` says whether either means anything.
    mutating func step(beat: Int, phase: Double, beatLocked: Bool, dropStarted: Bool, now: Double) -> Action {
        if lastSwitchTime < -1.0e8 { lastSwitchTime = now }       // the first preset counts as a switch
        guard beatLocked else {
            own = nil
            if locked { return .none }
            if dropStarted || now - lastSwitchTime >= unlockedHoldSeconds {
                lastSwitchTime = now; lastSwitchBeat = nil
                return dropStarted ? .cut : .blend
            }
            return .none
        }
        var wrapped = false
        if own == nil { own = beat; pendingOffset = 0; offsetRun = 0 }
        else if phase < lastPhase - 0.5 { own! += 1; wrapped = true }
        lastPhase = phase
        if dropStarted {
            // the drop is the new phrase grid: adopt the renderer's counter now (it re-aligns its phrase on the drop too)
            own = beat; pendingOffset = 0; offsetRun = 0
            if locked { return .none }
            lastSwitchBeat = beat; lastSwitchTime = now
            return .cut
        }
        if wrapped {
            let off = beat - own!
            if off == 0 { offsetRun = 0 } else if off == pendingOffset { offsetRun += 1 } else { pendingOffset = off; offsetRun = 1 }
            if offsetRun >= 8 {
                // a stable re-alignment (bar found, phrase shift after a drop): not elapsed time, so keep the hold intact
                own! += off
                if let last = lastSwitchBeat { lastSwitchBeat = last + off }
                offsetRun = 0
            }
        }
        // only on the frame a phrase downbeat begins
        guard !locked, wrapped, let b = own, Self.mod(b, phraseBeats) == 0 else { return .none }
        if let last = lastSwitchBeat, b - last < holdBeats, b >= last { return .none }
        if lastSwitchBeat == nil && now - lastSwitchTime < 4 { return .none }   // just switched while unlocked
        lastSwitchBeat = b; lastSwitchTime = now
        return .blend
    }

    /// The director's own beat counter (renderer's when not locked yet), for event logs.
    func beatForLog(_ rendererBeat: Int) -> Int { own ?? rendererBeat }

    /// Note a manual change (keys, browser) so the next automatic one waits a full hold.
    mutating func manualSwitch(now: Double) { lastSwitchBeat = own; lastSwitchTime = now }

    /// Blend length in seconds: `bars` whole bars at the current tempo (2 s when there is no tempo).
    static func blendSeconds(bpm: Double, bars: Int = 2) -> Double {
        bpm > 0 ? Double(bars * 4) * 60 / bpm : 2
    }

    static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
}
