// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import CoreMedia
import Foundation
import RaveAudio

/// Snapshot the renderer reads every frame. Written on the audio queue, read on the render thread.
struct AudioSnapshot {
    var bands = [Float](repeating: 0, count: 5)
    var energy: Float = 0
    var rms: Float = 0
    var bpm: Double = 0
    var confidence: Double = 0
    var beatPhase: Double = 0
    var phaseHostTime: Double = 0      // host time the beatPhase refers to
    var kickCount = 0, snareCount = 0, hatCount = 0, beatCount = 0
    var lastKickHostTime: Double = 0    // capture PTS (host clock) of the most recent kick
    var playing = false                 // sound present
    var silentFor: Double = 0           // seconds of continuous silence
    var energyShort: Float = 0          // ~0.5 s
    var energyLong: Float = 0           // ~8 s
    var source = "none"
    var droppedGaps = 0
    var referee: BeatReferee.Status?
    var beatIndex = 0                    // analyzer beat count at phaseHostTime
    var beatInBar = 0                    // bar position of that beat (0 = downbeat)
    var barConfidence = 0.0
    var waveform = [Float](repeating: 0, count: 512)
    var spectrum = [Float](repeating: 0, count: 128)
}

enum InputSource: String { case system, mic }

final class AudioEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var snap = AudioSnapshot()
    private var analyzer: LiveAnalyzer?
    private let sys = SystemAudioCapture()
    private let mic = MicCapture()
    private(set) var source: InputSource = .system
    private var lastSoundHost: Double = 0
    var onStatus: ((String) -> Void)?
    /// Raw mono capture samples (capture queue), e.g. for the MilkDrop engine.
    var onPCM: ((UnsafeBufferPointer<Float>) -> Void)?
    /// Beat This! referee sidecar (nil until it has loaded, or if the tools venv is missing).
    private var referee: BeatReferee?
    var refereeEnabled = true
    func startReferee() {
        guard refereeEnabled, referee == nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = BeatReferee()
            self?.lock.lock(); self?.referee = r; self?.lock.unlock()
            if r == nil { NSLog("RAVE LIVE: beat referee unavailable (tools/.venv missing)") }
        }
    }
    func stopReferee() { referee?.stop() }

    func snapshot() -> AudioSnapshot { lock.lock(); defer { lock.unlock() }; return snap }

    var tempo: TempoTracker? { analyzer?.tempo }

    func start(_ src: InputSource) async {
        source = src
        let handler: SampleHandler = { [weak self] buf, sr, pts in self?.ingest(buf, sr, pts) }
        switch src {
        case .system:
            if !CapturePermission.screenRecordingGranted { CapturePermission.requestScreenRecording() }
            sys.onSamples = handler
            sys.onError = { [weak self] e in self?.onStatus?("Capture error: \(e)") }
            do { try await sys.start(); onStatus?("") }
            catch { onStatus?(CapturePermission.fixInstructions) }
        case .mic:
            await sys.stop()
            _ = await MicCapture.requestPermission()
            mic.onSamples = handler
            do { try mic.start(); onStatus?("") } catch { onStatus?("Microphone failed: \(error.localizedDescription)") }
        }
    }

    /// Demo / test mode: a synthetic EDM arrangement (groove -> build -> gap -> drop) streamed through
    /// the same analysis path in real time. Nothing is played out loud.
    private var demoTimer: DispatchSourceTimer?
    func startDemo() {
        source = .system
        let sr = 48000.0
        var groove = Synth.house; groove.bpm = 128
        var buildA = Synth.Pattern(name: "build", bpm: 128, kick: "................", snare: "x...x...x...x...", hat: "..x...x...x...x.")
        var buildB = buildA; buildB.snare = "x.x.x.x.x.x.x.x."
        var buildC = buildA; buildC.snare = "xxxxxxxxxxxxxxxx"
        buildA.pad = true; buildB.pad = true; buildC.pad = true
        let beat = 60.0 / 128
        var audio: [Float] = []
        audio += Synth.render(groove, seconds: beat * 32, sr: sr).map { $0 * 0.5 }        // quiet intro
        audio += Synth.render(groove, seconds: beat * 32, sr: sr, seed: 2)               // groove
        let b1 = Synth.render(buildA, seconds: beat * 8, sr: sr, seed: 3)
        let b2 = Synth.render(buildB, seconds: beat * 4, sr: sr, seed: 4)
        let b3 = Synth.render(buildC, seconds: beat * 4, sr: sr, seed: 5)
        let build = b1 + b2 + b3
        audio += build.enumerated().map { i, v in v * Float(0.5 + 0.5 * Double(i) / Double(build.count)) }
        audio += [Float](repeating: 0.002, count: Int(beat * 2 * sr))                     // pre-drop gap
        var drop = Synth.house; drop.bpm = 128; drop.hat = "x.x.x.x.x.x.x.x."
        audio += Synth.render(drop, seconds: beat * 64, sr: sr, seed: 6).map { min(1, $0 * 1.3) }
        let chunk = 480
        var pos = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "rave.demo", qos: .userInteractive))
        let start = hostNow()
        t.schedule(deadline: .now(), repeating: .milliseconds(5))
        t.setEventHandler { [weak self] in
            // keep the feed locked to the wall clock
            let due = Int((hostNow() - start) * sr)
            while pos + chunk <= due {
                let i = pos % audio.count
                if i + chunk <= audio.count {
                    audio.withUnsafeBufferPointer { b in self?.ingest(UnsafeBufferPointer(rebasing: b[i..<(i + chunk)]), sr, start + Double(pos) / sr) }
                }
                pos += chunk
            }
        }
        t.resume(); demoTimer = t
        onStatus?("")
    }

    private func ingest(_ buf: UnsafeBufferPointer<Float>, _ sr: Double, _ pts: Double) {
        if analyzer == nil || analyzer!.sampleRate != sr { analyzer = LiveAnalyzer(sampleRate: sr) }
        let a = analyzer!
        let frames = a.process(buf)
        onPCM?(buf)
        lock.lock(); let ref = referee; lock.unlock()
        if let ref { ref.feed(buf, sampleRate: sr); ref.step(a) }
        guard !frames.isEmpty else { return }
        let bufEnd = pts + Double(buf.count) / sr
        let streamEnd = frames.last!.time
        lock.lock(); defer { lock.unlock() }
        for f in frames {
            // host time of this analysis frame = buffer end minus how far before the end it sits
            let host = bufEnd - (streamEnd - f.time)
            if f.kick { snap.kickCount += 1; snap.lastKickHostTime = host }
            if f.snare { snap.snareCount += 1 }
            if f.hat { snap.hatCount += 1 }
            if f.isBeat { snap.beatCount += 1 }
            if !f.silent { lastSoundHost = host }
            let k1: Float = 1 - expf(-1 / (93.75 * 0.5)), k2: Float = 1 - expf(-1 / (93.75 * 8))
            snap.energyShort += k1 * (f.rms - snap.energyShort)
            snap.energyLong += k2 * (f.rms - snap.energyLong)
        }
        let f = frames.last!
        snap.bands = f.bands
        snap.waveform = a.waveform
        snap.spectrum = a.spectrum
        snap.energy = f.energy
        snap.rms = f.rms
        snap.bpm = a.tempo.outputBPM > 0 ? a.tempo.outputBPM : 0
        snap.confidence = f.confidence
        snap.beatPhase = f.beatPhase
        snap.beatIndex = f.beatIndex
        snap.referee = ref?.status
        snap.beatInBar = f.beatInBar
        snap.barConfidence = f.barConfidence
        snap.phaseHostTime = bufEnd
        snap.silentFor = lastSoundHost > 0 ? max(0, bufEnd - lastSoundHost) : 999
        snap.playing = snap.silentFor < 0.15
        snap.source = source.rawValue
        snap.droppedGaps = sys.droppedGaps
    }
}

func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
