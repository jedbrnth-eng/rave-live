// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation
import CoreGraphics

/// The lyric looks (Settings → Lyrics → Style). Ideas credited in docs/THIRD_PARTY.md; all code here is original.
enum LyricStyle: String, CaseIterable {
    case clean, neon, pop, wave, spectrum, auto
    static let `default` = LyricStyle.clean

    var title: String {
        switch self {
        case .clean: return "Clean"
        case .neon: return "Neon karaoke"
        case .pop: return "Pop"
        case .wave: return "Bass wave"
        case .spectrum: return "Spectrum"
        case .auto: return "Auto (follows the energy)"
        }
    }
    var blurb: String {
        switch self {
        case .clean: return "White, calm: sung words brighten, the active word lifts a little. Breathes on the beat."
        case .neon: return "Karaoke fill sweeps through each word; the neon glow follows the song's energy."
        case .pop: return "One to three big words at a time, popping in with a spring; kicks punch them."
        case .wave: return "Letters ride a wave whose height follows the bass; each kick sends a ripple along the line."
        case .spectrum: return "Every word is an equaliser bar: its height follows its own frequency band."
        case .auto: return "Clean when it's quiet, Neon or Bass wave as the energy builds, Pop on drops."
        }
    }
    static func from(key: String?) -> LyricStyle { key.flatMap(LyricStyle.init(rawValue:)) ?? .default }
    /// Bass wave moves single letters; every other style moves whole words.
    var perGlyph: Bool { self == .wave }
    /// Pop shows a few words at a time instead of the whole line.
    var chunked: Bool { self == .pop }
    var uppercase: Bool { self == .pop }
}

/// Where the lyrics sit.
enum LyricPosition: String, CaseIterable {
    case lower, center
    static let `default` = LyricPosition.lower
    var title: String { self == .lower ? "Lower third" : "Centre" }
    static func from(key: String?) -> LyricPosition { key.flatMap(LyricPosition.init(rawValue:)) ?? .default }
}

/// One word with the time it is sung (song seconds). `end` is the next word's start (or the line's sung end).
struct TimedWord: Equatable, Codable {
    var text: String, start: Double, end: Double
}

/// The beat grid in song time: at song time `refTime` the beat phase was `refPhase` (0..1).
struct BeatGrid: Equatable {
    var bpm: Double, refTime: Double, refPhase: Double
    var beat: Double { 60 / bpm }
    /// Song time of the grid point (1/`division` beat) nearest to `t`.
    func nearest(_ t: Double, division: Double = 2) -> Double {
        let beats = refPhase + (t - refTime) / beat            // beat count, whole numbers on the beats
        let slot = (beats * division).rounded() / division
        return refTime + (slot - refPhase) * beat
    }
}

/// Word timing inside a line. LRCLIB is mostly one timestamp per line, so the words are spread over the time the line is
/// sung (by syllables), then snapped to the live beat grid: rap and pop vocals land on 8th notes, so a snapped estimate
/// feels sung-along where an even spread drifts. Enhanced LRC word tags, when present, are used as they are.
enum WordTiming {
    /// Rough English syllable count (vowel groups, silent final e), at least 1. Good enough to weight word lengths.
    static func syllables(_ w: String) -> Int {
        let s = w.lowercased().filter { $0.isLetter }
        guard !s.isEmpty else { return 1 }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var n = 0, prevVowel = false
        for c in s { let v = vowels.contains(c); if v && !prevVowel { n += 1 }; prevVowel = v }
        if s.count > 2, s.hasSuffix("e"), !s.hasSuffix("le"), n > 1 { n -= 1 }
        return max(1, n)
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }

    /// Spread `text` from `start` until `nextStart` (the next line's time). A line is sung over at most ~90 % of the gap
    /// and no slower than a relaxed pace, so a line followed by a long instrumental gap still finishes in time.
    static func estimate(text: String, start: Double, nextStart: Double?) -> [TimedWord] {
        let ws = words(text)
        guard !ws.isEmpty else { return [] }
        let gap = max(0.3, min(12, (nextStart ?? start + 4) - start))
        let syl = ws.map { Double(syllables($0)) }
        let natural = syl.reduce(0) { $0 + 0.16 + 0.19 * $1 }     // relaxed pace: ~0.19 s per syllable + a little per word
        let span = max(0.25, min(gap * 0.9, natural * 1.35))
        var weights: [Double] = []
        for s in syl { weights.append(0.6 + s) }
        let total = weights.reduce(0, +)
        var out: [TimedWord] = []
        var t = start
        for (i, w) in ws.enumerated() {
            let d = span * weights[i] / total
            out.append(TimedWord(text: w, start: t, end: t + d))
            t += d
        }
        return out
    }

    /// Snap every word after the first to the nearest 8th note when it is already close (within 35 % of an 8th), keeping
    /// the order and at least 70 ms per word. The first word keeps the line's own timestamp (that one is measured).
    static func quantize(_ ws: [TimedWord], grid: BeatGrid?) -> [TimedWord] {
        guard let g = grid, g.bpm >= 50, g.bpm <= 220, ws.count > 1 else { return ws }
        let eighth = g.beat / 2
        var out = ws
        for i in 1..<out.count {
            let s = ws[i].start
            let q = g.nearest(s, division: 2)
            guard abs(q - s) <= 0.35 * eighth else { continue }
            let lo = out[i - 1].start + 0.07
            let hi = (i + 1 < ws.count ? ws[i + 1].start : ws[i].end) - 0.07
            if q >= lo && q <= hi { out[i].start = q }
        }
        for i in 0..<out.count { out[i].end = i + 1 < out.count ? out[i + 1].start : max(ws[i].end, out[i].start + 0.12) }
        return out
    }

    /// The words of `line` with times: its own word tags if it has them, otherwise estimated and snapped to the grid.
    static func timed(_ line: LyricLine, nextStart: Double?, grid: BeatGrid?) -> [TimedWord] {
        if let w = line.words, !w.isEmpty { return w }
        return quantize(estimate(text: line.text, start: line.time, nextStart: nextStart), grid: grid)
    }

    /// Pop: groups of up to `size` words, breaking after punctuation. Returns word index ranges.
    static func chunks(_ ws: [TimedWord], size: Int = 3) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var a = 0
        for i in ws.indices {
            let punct = ws[i].text.last.map { ",.!?;:".contains($0) } ?? false
            if i - a + 1 >= size || punct || i == ws.count - 1 { out.append(a..<(i + 1)); a = i + 1 }
        }
        return out
    }
}

/// What the music is doing this frame, as the lyrics see it (from the renderer, on the heard timeline).
struct LyricDrive: Equatable {
    var beatPhase = 0.0
    var locked = false
    var bpm = 0.0
    /// Eased kick pulse 0..1 (same one the visuals use).
    var kick: Float = 0
    /// Smoothed bands low → high (5).
    var bands: [Float] = [0, 0, 0, 0, 0]
    var energy: Float = 0
    var drop: Float = 0
    var build: Float = 0
    /// Settings → Strobe effects. Off = photosensitive-safe: no fast brightness changes in the lyrics either.
    var strobe = true
    var bass: Float { max(bands[0], bands.count > 1 ? bands[1] : 0) }
}

/// Beat-reactive parameter math, shared by all styles. Pure functions so they are unit-tested.
enum LyricFX {
    /// 0..1, peaks on the beat and is back to 0 by 30 % of the beat away from it. 0 while the tempo isn't locked.
    static func beatPulse(phase: Double, locked: Bool) -> Double {
        guard locked, phase.isFinite else { return 0 }
        let p = phase - floor(phase)
        let d = min(p, 1 - p) / 0.3
        guard d < 1 else { return 0 }
        let c = cos(d * Double.pi / 2)
        return c * c
    }

    /// Damped spring step response for word entrances: 0 at t = 0, overshoots ~10-15 %, settles at 1.
    /// (The spring feel follows Beautiful Lyrics' idea; this is a plain analytic spring.)
    static func spring(_ t: Double, freq: Double = 2.6, damping: Double = 0.5) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi * freq
        let wd = w * sqrt(max(1e-6, 1 - damping * damping))
        let e = exp(-damping * w * t)
        return 1 - e * (cos(wd * t) + damping * w / wd * sin(wd * t))
    }

    static func easeOut(_ x: Double) -> Double { let c = max(0, min(1, x)); return 1 - (1 - c) * (1 - c) * (1 - c) }

    /// How far through word `w` the voice is at song time `t` (0 before, 1 after).
    static func progress(_ t: Double, _ w: TimedWord) -> Double {
        let d = max(0.05, w.end - w.start)
        return max(0, min(1, (t - w.start) / d))
    }

    /// Extra scale from a kick (and the bass under it). Photosensitive mode halves it; never more than +9 %.
    static func punch(kick: Float, bass: Float, strobe: Bool) -> Double {
        let k = Double(max(0, min(1, kick))) * (0.6 + 0.4 * Double(max(0, min(1, bass))))
        return min(0.09, k * (strobe ? 0.09 : 0.045))
    }

    /// Glow strength 0..1 from the energy, lifted on drops.
    static func glow(energy: Float, drop: Float) -> Double {
        let e = Double(max(0, min(1, energy))), d = Double(max(0, min(1, drop)))
        return min(1, 0.25 + 0.6 * e + 0.25 * d)
    }

    /// Photosensitivity: brightness/opacity values may only move this fast (units per second). With strobe effects off a
    /// full 0 → 1 swing takes 0.4 s, so the text can't flash faster than ~1.2 times a second; with them on, 0.12 s.
    static func maxRate(strobe: Bool) -> Double { strobe ? 8 : 2.5 }
    static func slew(_ current: Double, toward target: Double, dt: Double, strobe: Bool) -> Double {
        let step = maxRate(strobe: strobe) * max(0, dt)
        return current + max(-step, min(step, target - current))
    }
}

/// Auto style: picks a look from the song's energy. Changes wait for a line change and hold at least 8 s, so it never
/// flips mid-word; a drop is the one exception: Pop cuts in on the drop itself and rides it for 16 s.
struct AutoStyle {
    private(set) var current: LyricStyle = .clean
    private var since = -1e9
    private var dropAt = -1e9
    private var lastDrop: Float = 0
    static let hold = 8.0, dropHold = 16.0

    static func target(energy: Float, drop: Float, build: Float) -> LyricStyle {
        if drop > 0.5 { return .pop }
        if build > 0.5 || energy > 0.7 { return .neon }
        if energy > 0.45 { return .wave }
        return .clean
    }

    mutating func update(energy: Float, drop: Float, build: Float, now: Double, atLineChange: Bool) -> LyricStyle {
        defer { lastDrop = drop }
        if drop > 0.5 && lastDrop <= 0.5 { dropAt = now; current = .pop; since = now; return current }
        if now - dropAt < Self.dropHold { return current }
        let t = Self.target(energy: energy, drop: drop, build: build)
        if atLineChange && t != current && (now - since >= Self.hold || t == .pop) { current = t; since = now }
        return current
    }
}

/// Greedy word wrap into at most `maxRows` centred rows. Returns each word's rect (y grows up, row 0 on top) and the
/// block size. Words that don't fit in the last row are squeezed by the caller's font scale, never dropped.
enum LyricLayout {
    static func layout(widths: [CGFloat], space: CGFloat, maxWidth: CGFloat, rowHeight: CGFloat, maxRows: Int = 2) -> (rects: [CGRect], size: CGSize) {
        guard !widths.isEmpty else { return ([], .zero) }
        var rows: [[Int]] = [[]]
        var rowW: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let add = rows[rows.count - 1].isEmpty ? w : space + w
            if !rows[rows.count - 1].isEmpty && rowW + add > maxWidth && rows.count < maxRows {
                rows.append([i]); rowW = w
            } else { rows[rows.count - 1].append(i); rowW += add }
        }
        // balance two rows (move words down while row 0 is clearly longer) so a wrapped line doesn't leave one word alone
        if rows.count == 2 {
            func width(_ r: [Int]) -> CGFloat { r.reduce(0) { $0 + widths[$1] } + space * CGFloat(max(0, r.count - 1)) }
            while rows[0].count > 1, width(rows[0]) - widths[rows[0].last!] - space >= width(rows[1]) + widths[rows[0].last!] + space - 1 {
                rows[1].insert(rows[0].removeLast(), at: 0)
                if width(rows[1]) > maxWidth { rows[0].append(rows[1].removeFirst()); break }
            }
        }
        var rects = [CGRect](repeating: .zero, count: widths.count)
        var blockW: CGFloat = 0
        for r in rows { blockW = max(blockW, r.reduce(0) { $0 + widths[$1] } + space * CGFloat(max(0, r.count - 1))) }
        let h = rowHeight * CGFloat(rows.count)
        for (ri, r) in rows.enumerated() {
            let rw = r.reduce(0) { $0 + widths[$1] } + space * CGFloat(max(0, r.count - 1))
            var x = (blockW - rw) / 2
            let y = h - rowHeight * CGFloat(ri + 1)
            for i in r { rects[i] = CGRect(x: x, y: y, width: widths[i], height: rowHeight); x += widths[i] + space }
        }
        return (rects, CGSize(width: blockW, height: h))
    }
}
