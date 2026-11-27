// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation
#if canImport(RaveLiveApp)
@testable import RaveLiveApp
#endif

/// What one synthetic set did to the breath (`ShowDirector.Output.gap`).
struct BreathRun {
    var gaps: [Float] = []
    var drops: [Double] = []
    var maxGap: Float = 0
    /// Longest unbroken stretch with the gap above 0.5, in seconds.
    var longestDip: Double = 0
    /// Number of separate stretches with the gap above 0.5.
    var dips: Int = 0
    /// Most direction changes of 0.15 or more inside any one second. Two changes make one down-and-up pair.
    var worstSwingsInOneSecond: Int = 0
    /// Largest one-frame fall of the gap on a frame that is not a drop.
    var maxFallPerFrame: Float = 0
    var pairsPerSecond: Double { return Double(worstSwingsInOneSecond) / 2 }
}

/// Drives the real `ShowDirector` at 60 fps with a synthetic level and onsets, smoothed the way the analyzer does it
/// (0.5 s and 8 s averages at 93.75 analysis frames a second). No audio, no window, no files.
/// It has no XCTest in it, so it also compiles on its own next to `ShowDirector.swift` for a quick measurement.
enum BreathHarness {
    static let fps: Double = 60
    static let beat: Double = 60.0 / 128

    static func run(seconds: Double, level: (Double) -> Float, snareRate: (Double) -> Double, kickRate: (Double) -> Double) -> BreathRun {
        let d = ShowDirector()
        let analysisRate: Double = 93.75
        let k1: Float = 1 - expf(-1 / Float(analysisRate * 0.5))
        let k2: Float = 1 - expf(-1 / Float(analysisRate * 8))
        var eShort: Float = 0
        var eLong: Float = 0
        var aT: Double = 0
        var t: Double = 0
        var nextSnare: Double = 0
        var nextKick: Double = 0
        var r = BreathRun()
        var dipRun: Double = 0
        var dropFrames = Set<Int>()
        var seenDrops: Int = 0
        var frame: Int = 0
        while t < seconds {
            while aT <= t {
                let l: Float = level(aT)
                eShort += k1 * (l - eShort)
                eLong += k2 * (l - eLong)
                aT += 1 / analysisRate
            }
            var snare = false
            var kick = false
            let sr: Double = snareRate(t)
            let kr: Double = kickRate(t)
            if sr > 0 && t >= nextSnare { snare = true; nextSnare = t + 1 / sr } else if sr <= 0 { nextSnare = t }
            if kr > 0 && t >= nextKick { kick = true; nextKick = t + 1 / kr } else if kr <= 0 { nextKick = t }
            let l: Float = level(t)
            let input = ShowDirector.Input(now: t, dt: Float(1 / fps), energy: min(1, l * 1.2), energyShort: eShort, energyLong: eLong,
                                           kick: kick, snare: snare, beatIndex: Int(t * 128 / 60), beatLocked: true, playing: l > 0.003)
            let o = d.step(input)
            var dropCount: Int = 0
            for e in d.events where e.1.hasPrefix("drop") { dropCount += 1 }
            if dropCount > seenDrops { seenDrops = dropCount; dropFrames.insert(frame); r.drops.append(t) }
            r.gaps.append(o.gap)
            if o.gap > r.maxGap { r.maxGap = o.gap }
            if o.gap > 0.5 {
                if dipRun == 0 { r.dips += 1 }
                dipRun += 1 / fps
                if dipRun > r.longestDip { r.longestDip = dipRun }
            } else {
                dipRun = 0
            }
            t += 1 / fps
            frame += 1
        }
        if r.gaps.count > 1 {
            for i in 1..<r.gaps.count where !dropFrames.contains(i) {
                let fall: Float = r.gaps[i - 1] - r.gaps[i]
                if fall > r.maxFallPerFrame { r.maxFallPerFrame = fall }
            }
        }
        r.worstSwingsInOneSecond = worstSwings(r.gaps)
        return r
    }

    /// Alternating extremes of the gap that are 0.15 or more apart, then the most reversals inside one second.
    static func worstSwings(_ gaps: [Float]) -> Int {
        let swing: Float = 0.15
        var extremes: [Int] = []      // frame index of each extreme
        var dir: Int = 0
        var lo: Float = gaps.first ?? 0
        var hi: Float = lo
        var loIdx: Int = 0
        var hiIdx: Int = 0
        for i in 0..<gaps.count {
            let g: Float = gaps[i]
            if dir == 0 {
                if g > hi { hi = g; hiIdx = i }
                if g < lo { lo = g; loIdx = i }
                if g >= lo + swing { extremes.append(loIdx); dir = 1; hi = g; hiIdx = i } else if g <= hi - swing { extremes.append(hiIdx); dir = -1; lo = g; loIdx = i }
            } else if dir == 1 {
                if g > hi { hi = g; hiIdx = i } else if g <= hi - swing { extremes.append(hiIdx); dir = -1; lo = g; loIdx = i }
            } else {
                if g < lo { lo = g; loIdx = i } else if g >= lo + swing { extremes.append(loIdx); dir = 1; hi = g; hiIdx = i }
            }
        }
        if dir == 1 { extremes.append(hiIdx) } else if dir == -1 { extremes.append(loIdx) }
        var worst: Int = 0
        for i in 0..<extremes.count {
            var n: Int = 0
            for j in i..<extremes.count where extremes[j] - extremes[i] <= Int(fps) { n += 1 }
            if n - 1 > worst { worst = n - 1 }
        }
        return worst
    }

    // MARK: the sets

    /// Groove 16 s, an 8-beat snare build, 2 beats of silence, then the drop.
    static func designedDrop() -> BreathRun {
        let b = beat
        return run(seconds: 30,
                   level: { (t: Double) -> Float in t < 16 + 8 * b ? 0.5 : (t < 16 + 10 * b ? 0.002 : 0.7) },
                   snareRate: { (t: Double) -> Double in t < 16 ? 1 / (2 * b) : (t < 16 + 8 * b ? 2 / b : (t < 16 + 10 * b ? 0 : 1 / (2 * b))) },
                   kickRate: { (t: Double) -> Double in t < 16 ? 1 / b : (t < 16 + 10 * b ? 0 : 1 / b) })
    }

    /// Groove 16 s at level 0.5, then 44 s of a quiet breakdown with a steady 8th-note snare roll and no kick.
    static func quietBreakdown(level quiet: Float) -> BreathRun {
        let b = beat
        return run(seconds: 60,
                   level: { (t: Double) -> Float in t < 16 ? 0.5 : quiet },
                   snareRate: { (t: Double) -> Double in t < 16 ? 1 / (2 * b) : 2 / b },
                   kickRate: { (t: Double) -> Double in t < 16 ? 1 / b : 0 })
    }

    /// Groove 16 s, then the music fades through the point where short / long = 0.6 while the level pulses on every
    /// hit of a roll (`rate` hits a second; a quarter of each period at `peakMul` times the mean).
    static func pulsingFade(rate: Double, base: Float, slope: Float, peakMul: Float) -> BreathRun {
        let b = beat
        let level: (Double) -> Float = { (t: Double) -> Float in
            if t < 16 { return 0.5 }
            let mean: Float = max(0.02, base - slope * Float(t - 16))
            let phase: Double = (t * rate).truncatingRemainder(dividingBy: 1)
            return mean * (phase < 0.25 ? peakMul : (4 - peakMul) / 3)
        }
        return run(seconds: 40, level: level,
                   snareRate: { (t: Double) -> Double in t < 16 ? 1 / (2 * b) : max(rate, 2 / b) },
                   kickRate: { (t: Double) -> Double in t < 16 ? 1 / b : 0 })
    }

    struct ScanResult {
        var rate: Double
        var fades: Int = 0
        var overLimit: Int = 0
        var worstPairsPerSecond: Double = 0
        var worst: (base: Float, slope: Float, peakMul: Float) = (0, 0, 0)
    }

    /// 132 fades at one pulse rate: 11 starting levels x 4 fade speeds x 3 pulse heights.
    static func scan(rate: Double) -> ScanResult {
        var s = ScanResult(rate: rate)
        let slopes: [Float] = [0, 0.004, 0.008, 0.016]
        let peaks: [Float] = [2.0, 3.0, 4.0]
        for step in 0...10 {
            let base: Float = 0.20 + 0.02 * Float(step)
            for slope in slopes {
                for peakMul in peaks {
                    let r = pulsingFade(rate: rate, base: base, slope: slope, peakMul: peakMul)
                    s.fades += 1
                    if r.pairsPerSecond > 3 { s.overLimit += 1 }
                    if r.pairsPerSecond > s.worstPairsPerSecond { s.worstPairsPerSecond = r.pairsPerSecond; s.worst = (base, slope, peakMul) }
                }
            }
        }
        return s
    }

    /// Quarter, 8th and 16th notes at 128 BPM: 2.1, 4.3 and 8.5 hits a second.
    static let pulseRates: [Double] = [1 / beat, 2 / beat, 4 / beat]
}
