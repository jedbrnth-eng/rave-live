// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Accelerate
import Foundation

/// One analysis hop (~10.7 ms at 48 kHz / hop 512).
public struct AnalysisFrame: Sendable {
    public var time: Double                 // stream time in seconds (sample clock)
    public var bands: [Float]               // sub, bass, lowMid, mid, high — auto-gained 0...1
    public var rms: Float                   // raw RMS of the hop
    public var energy: Float                // smoothed energy envelope 0...1 (auto-gained)
    public var onset: Float                 // broadband spectral flux
    public var kick: Bool
    public var snare: Bool
    public var hat: Bool
    public var bpm: Double                  // 0 when no tempo yet
    public var confidence: Double           // 0...1
    public var beatPhase: Double            // 0...1 position inside the current beat
    public var isBeat: Bool                 // true on the frame a predicted beat lands
    public var nextBeatTime: Double         // predicted stream time of the next beat
    public var silent: Bool
    public var beatIndex: Int = 0           // predicted beats since start
    public var beatInBar: Int = 0           // 0 = downbeat (bar position of the most recent beat)
    public var barConfidence: Double = 0    // 0...1 how clear the bar accent pattern is
    /// Exact stream time of the beat that landed on this frame (only meaningful when isBeat).
    public var beatTime: Double = 0
}

/// Downbeat (bar position) tracker. Real music accents beat 1 of the bar: the kick/bass is
/// strongest and chords change there. We gather low-frequency onset energy in a small window
/// around every predicted beat into 4 leaky bins (beat index mod 4) and call the strongest bin beat 1.
/// Causal, ~0 cost, re-converges in a few bars after a DJ transition.
public final class BarTracker {
    public private(set) var bins = [Double](repeating: 0, count: 4)
    public private(set) var offset = 0             // which (beatIndex mod 4) is the downbeat
    public private(set) var confidence = 0.0
    private var pending = 0.0                      // accent collected for the beat being approached
    private var pendingTarget = -1
    public var decay = 0.88                        // per beat; ~8 bars memory
    public init() {}

    /// Feed every analysis frame: phase (0..1 inside the beat), the index of the beat just passed,
    /// and this frame's low-frequency accent.
    public func push(phase: Double, beatIndex: Int, accent: Double) {
        // frames near a beat: last 12% before it belongs to the next beat, first 12% to this one
        let target = phase > 0.88 ? beatIndex + 1 : (phase < 0.12 ? beatIndex : -1)
        if target != pendingTarget {
            if pendingTarget >= 0 { commit(pendingTarget, pending) }
            pendingTarget = target; pending = 0
        }
        if target >= 0 { pending = max(pending, accent) }
    }

    private func commit(_ beat: Int, _ a: Double) {
        let k = ((beat % 4) + 4) % 4
        for i in 0..<4 { bins[i] *= decay }
        bins[k] += a
        let sorted = bins.sorted(by: >)
        let best = bins.firstIndex(of: sorted[0]) ?? 0
        let c = sorted[0] > 1e-9 ? (sorted[0] - sorted[1]) / sorted[0] : 0
        confidence = 0.8 * confidence + 0.2 * min(1, c * 3)
        // hysteresis: only move the bar line when the new winner is clearly ahead
        if best != offset && bins[best] > bins[offset] * 1.15 { offset = best }
    }

    /// Referee override (downbeats from Beat This!), wins over the accent heuristic while fresh.
    public var refereeOffset: Int?
    public func setReferee(offset o: Int?) { refereeOffset = o.map { (($0 % 4) + 4) % 4 }; if o != nil { confidence = 1 } }
    public func beatInBar(_ beatIndex: Int) -> Int { (((beatIndex - (refereeOffset ?? offset)) % 4) + 4) % 4 }
}

public enum Band: Int, CaseIterable { case sub, bass, lowMid, mid, high
    public var range: (Double, Double) {
        switch self {
        case .sub: return (20, 60)
        case .bass: return (60, 250)
        case .lowMid: return (250, 500)
        case .mid: return (500, 2000)
        case .high: return (2000, 16000)
        }
    }
}

/// Streaming analyzer: push mono samples in any chunk size, get one frame per hop.
/// No look-ahead and no pre-scan; everything works on a rolling window.
public final class LiveAnalyzer {
    public let sampleRate: Double
    public let fftSize: Int
    public let hop: Int
    public var fps: Double { sampleRate / Double(hop) }
    public let tempo: TempoTracker

    /// RMS below this (≈ -60 dBFS) counts as silence.
    public var silenceRMS: Float = 0.001

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringFill = 0
    private var pendingSinceHop = 0
    private var samplesSeen: Int = 0
    private var prevLogMag: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var frameBuf: [Float]
    private var bandBins: [(Int, Int)] = []
    private var bandPeak = [Float](repeating: 1e-6, count: 5)
    private var energyPeak: Float = 1e-6
    private var energySmooth: Float = 0
    private let kickDet: OnsetPicker
    private let snareDet: OnsetPicker
    private let hatDet: OnsetPicker
    private var kickBins = (0, 0), snareBins = (0, 0), hatBins = (0, 0)
    private var frameIndex = 0
    public let bar = BarTracker()
    public private(set) var beatCount = 0
    /// Recent predicted beats (index, stream time) for referee alignment.
    public private(set) var beatHistory: [(index: Int, time: Double)] = []
    public var streamTime: Double { Double(samplesSeen) / sampleRate }
    private var bassPrev: Float = 0
    /// Latest trigger-aligned waveform (512 points, -1...1) for oscilloscope-style visuals.
    public private(set) var waveform = [Float](repeating: 0, count: 512)
    /// Latest log-frequency spectrum (128 bins, 30 Hz-16 kHz, auto-gained 0...1).
    public private(set) var spectrum = [Float](repeating: 0, count: 128)
    private var specPeak: Float = 1e-6
    private var logBinEdges: [Int] = []

    public init(sampleRate: Double = 48000, fftSize: Int = 2048, hop: Int = 512) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hop = hop
        log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        prevLogMag = [Float](repeating: 0, count: fftSize / 2)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        mags = [Float](repeating: 0, count: fftSize / 2)
        frameBuf = [Float](repeating: 0, count: fftSize)
        let fps = sampleRate / Double(hop)
        tempo = TempoTracker(fps: fps)
        kickDet = OnsetPicker(fps: fps, refractory: 0.12)
        snareDet = OnsetPicker(fps: fps, refractory: 0.12)
        hatDet = OnsetPicker(fps: fps, refractory: 0.06)
        let binHz = sampleRate / Double(fftSize)
        func bins(_ lo: Double, _ hi: Double) -> (Int, Int) {
            (max(1, Int(lo / binHz)), min(fftSize / 2 - 1, max(Int(lo / binHz) + 1, Int(hi / binHz))))
        }
        bandBins = Band.allCases.map { bins($0.range.0, $0.range.1) }
        kickBins = bins(30, 150)
        snareBins = bins(1500, 5000)
        hatBins = bins(7000, 16000)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public func process(_ samples: UnsafeBufferPointer<Float>) -> [AnalysisFrame] {
        var out: [AnalysisFrame] = []
        for s in samples {
            ring[ringFill % fftSize] = s
            ringFill += 1
            pendingSinceHop += 1
            samplesSeen += 1
            if pendingSinceHop == hop {
                pendingSinceHop = 0
                if ringFill >= fftSize { out.append(analyzeFrame()) }
            }
        }
        return out
    }

    public func process(_ samples: [Float]) -> [AnalysisFrame] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    private func analyzeFrame() -> AnalysisFrame {
        // Unroll ring into chronological order.
        let start = ringFill % fftSize
        for i in 0..<fftSize { frameBuf[i] = ring[(start + i) % fftSize] }
        // Oscilloscope: trigger on a rising zero crossing so the trace stands still, then decimate x2.
        var trig = fftSize - 1024                      // newest window that still fits
        for i in stride(from: fftSize - 1024, to: 0, by: -1) where frameBuf[i - 1] < 0 && frameBuf[i] >= 0 { trig = i; break }
        for i in 0..<512 { waveform[i] = frameBuf[trig + i * 2] }
        // RMS over the newest hop.
        var rms: Float = 0
        frameBuf.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + (fftSize - hop), 1, &rms, vDSP_Length(hop))
        }
        vDSP_vmul(frameBuf, 1, window, 1, &frameBuf, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frameBuf.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }
        mags[0] = 0 // packed DC/Nyquist
        var scale = Float(1.0 / Double(fftSize))
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(mags.count))

        // Log-frequency spectrum for visuals.
        if logBinEdges.isEmpty {
            let binHz = sampleRate / Double(fftSize)
            logBinEdges = (0...128).map { i in max(1, min(fftSize / 2 - 1, Int(30 * pow(16000.0 / 30, Double(i) / 128) / binHz))) }
        }
        var smax: Float = 0
        for b in 0..<128 {
            let lo = logBinEdges[b], hi = max(lo + 1, logBinEdges[b + 1])
            var m: Float = 0
            for k in lo..<hi { m = max(m, mags[k]) }
            let v = log1pf(2000 * m)
            spectrum[b] = v; smax = max(smax, v)
        }
        specPeak = max(smax, specPeak * 0.999)
        for b in 0..<128 { spectrum[b] = min(1, spectrum[b] / specPeak) }

        // Log-compressed spectral flux (half-wave rectified).
        var flux: Float = 0, kf: Float = 0, sf: Float = 0, hf: Float = 0
        for k in 1..<(fftSize / 2) {
            let lm = log1pf(1000 * mags[k])
            let d = lm - prevLogMag[k]
            prevLogMag[k] = lm
            if d > 0 {
                flux += d
                if k >= kickBins.0 && k <= kickBins.1 { kf += d }
                if k >= snareBins.0 && k <= snareBins.1 { sf += d }
                if k >= hatBins.0 && k <= hatBins.1 { hf += d }
            }
        }
        kf /= Float(kickBins.1 - kickBins.0 + 1)
        sf /= Float(snareBins.1 - snareBins.0 + 1)
        hf /= Float(hatBins.1 - hatBins.0 + 1)

        // Band energies with slow-decay auto gain so visuals always use 0...1.
        var bands = [Float](repeating: 0, count: 5)
        for (i, b) in bandBins.enumerated() {
            var e: Float = 0
            for k in b.0...b.1 { e += mags[k] * mags[k] }
            e = sqrtf(e / Float(b.1 - b.0 + 1))
            bandPeak[i] = max(e, bandPeak[i] * 0.9995)
            bands[i] = min(1, e / bandPeak[i])
        }
        let silent = rms < silenceRMS
        // Energy envelope: fast attack, slower release, auto-gained.
        let a: Float = rms > energySmooth ? 0.3 : 0.02
        energySmooth += a * (rms - energySmooth)
        energyPeak = max(energySmooth, energyPeak * 0.9998)
        let energy = min(1, energySmooth / energyPeak)

        frameIndex += 1
        let t = Double(samplesSeen) / sampleRate
        let kickNow = !silent && kickDet.push(kf)
        let beat = tempo.push(onset: silent ? 0 : flux, low: silent ? 0 : kf, kickHit: kickNow, frame: frameIndex)
        if beat.isBeat { beatCount += 1 }
        // low-frequency accent: kick-band flux + rise in sub/bass energy
        let bassNow = bands[0] + bands[1]
        let accent = Double(kf) + 0.5 * Double(max(0, bassNow - bassPrev))
        bassPrev = bassNow
        if tempo.bpm > 0 && !silent { bar.push(phase: beat.phase, beatIndex: beatCount, accent: accent) }
        let period = tempo.outputBPM > 0 ? 60 / tempo.outputBPM : 0
        var fr = AnalysisFrame(
            time: t, bands: bands, rms: rms, energy: silent ? 0 : energy, onset: flux,
            kick: kickNow, snare: !silent && snareDet.push(sf), hat: !silent && hatDet.push(hf),
            bpm: tempo.bpm, confidence: tempo.confidence,
            beatPhase: beat.phase, isBeat: beat.isBeat,
            nextBeatTime: t + beat.framesToNext / fps, silent: silent)
        fr.beatIndex = beatCount
        fr.beatInBar = bar.beatInBar(beatCount)
        fr.barConfidence = bar.confidence
        fr.beatTime = fr.nextBeatTime - period
        if beat.isBeat {
            beatHistory.append((beatCount, fr.beatTime))
            if beatHistory.count > 64 { beatHistory.removeFirst(beatHistory.count - 64) }
        }
        return fr
    }
}

/// Causal peak picker: fires on a frame that exceeds an adaptive threshold
/// and the previous frame, with a refractory period.
final class OnsetPicker {
    private var hist: [Float]
    private var idx = 0
    private var prev: Float = 0
    private var sinceFire = 1000
    private let refractory: Int
    init(fps: Double, refractory: Double) {
        hist = [Float](repeating: 0, count: max(8, Int(fps * 0.4)))
        self.refractory = Int(fps * refractory)
    }
    func push(_ v: Float) -> Bool {
        var mean: Float = 0, sq: Float = 0
        vDSP_meanv(hist, 1, &mean, vDSP_Length(hist.count))
        vDSP_measqv(hist, 1, &sq, vDSP_Length(hist.count))
        let sd = sqrtf(max(0, sq - mean * mean))
        hist[idx % hist.count] = v
        idx += 1
        sinceFire += 1
        let fire = v > mean + 1.5 * sd + 0.02 && v > prev && sinceFire > refractory
        prev = v
        if fire { sinceFire = 0 }
        return fire
    }
}
