// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import CoreMedia
import Metal
import MetalKit
import QuartzCore

/// Turns audio snapshots into show state (envelopes, strobe limiter, crowd behaviour) and renders.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let transitionPipeline: MTLRenderPipelineState
    let audio: AudioEngine
    var u = [Float](repeating: 0, count: 48)

    // Show controls
    var strobeEnabled = true
    var strobeOverride = false        // user lifted the 3 Hz cap (warning shown)
    var blackout = false
    var stage: Float = 0
    var hudVisible = true
    var manualStrobe = false          // MIDI strobe pad held; goes through the same flash limiter
    var frameOutput: FrameOutput?     // VJ output stage: brightness, Syphon, output-display preview
    var beatClockIndex: Float { beatIdx }

    // Show state
    private var t0 = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    private var kickEnv: Float = 0, snareEnv: Float = 0, hatEnv: Float = 0      // raw onset envelopes (triggers, limiter logic)
    // what the visuals see: eased attack/release pulses and smoothed band levels (Smoothing.swift)
    private var kickPulse = Pulse(attack: 0.018, release: 0.16), predPulse = Pulse(attack: 0.018, release: 0.16)
    private var snarePulse = Pulse(attack: 0.016, release: 0.14), hatPulse = Pulse(attack: 0.014, release: 0.10)
    private var strobePulse = Pulse(attack: 0.010, release: 0.07)
    private var pulseIntensity: Intensity?
    private var smoother = AudioSmoother()
    /// The predicted kick fires this far ahead of its grid slot so the eased pulse peaks on the beat, not after it.
    private let kickLead = 0.04
    private var lastKick = 0, lastSnare = 0, lastHat = 0
    private var fade: Float = 0
    private var strobe: Float = 0
    private var lastFlash: Double = 0
    let director = ShowDirector()
    /// How hard the show hits. Normal (default) keeps it on beat without being overwhelming.
    enum Intensity: Int, CaseIterable { case chill, normal, wild
        var title: String { ["Chill", "Normal", "Wild"][rawValue] }
        var pulse: Float { [0.45, 0.7, 1.0][rawValue] }     // beat/kick flash strength
        var shake: Float { [0.0, 0.25, 1.0][rawValue] }     // camera shake on hits
        /// Eased hits (docs/SMOOTHNESS.md): attack / release time constants in seconds. Wild stays punchier.
        var kickAR: (Float, Float) { [(0.022, 0.20), (0.018, 0.16), (0.010, 0.12)][rawValue] }
        var beatRelease: Double { [0.17, 0.13, 0.09][rawValue] }
    }
    var intensity: Intensity = .normal
    enum Mode: Int, CaseIterable { case show, stage, visuals, aurora, milkdrop
        var title: String { ["SHOW (auto)", "Stage", "Classic Visuals", "AURORA", "MILKDROP"][rawValue] }
        var probeName: String { ["show", "stage", "visuals", "aurora", "milkdrop"][rawValue] } }
    var mode: Mode = .show
    var visualsMode: Bool { mode == .visuals }
    var aurora: AuroraRenderer?
    var camera: HandTracker?
    var mousePointer: AuroraRenderer.Pointer?
    var fakeHands = false
    var fakeMouseFrom = -1.0         // scripted mouse (hover, drag, click) from this time (s); <0 = off
    var fakeHandsFrom = 0.0          // scripted hands start at this time (s): lets a test snapshot "before" and "after"
    private var handPrev: [SIMD2<Float>] = []
    private var pinchPrev: [Bool] = []
    var onModeChange: ((Mode) -> Void)?
    var visuals: VisualsRenderer?
    var milk: MilkDropRenderer?
    private var lastDropTime = -100.0
    private var eventsLogged = 0
    private var strobeFromBlinder = false
    var forcedLook: Float?, forcedBeam: Float?, forcedLaser: Float?
    private var jump: Float = 0, hands: Float = 0, density: Float = 0.3
    private var lowSince: Double = 0
    private var beatIdx: Float = 0
    private var beatCounter = BeatCounter()
    private var clock = 0.0, clockBase = 0.0      // continuous beat clock (u[37]) and its whole-phrase offset
    private var wasLocked = false
    private var lastBeatPhase: Double = 0
    var outputLatency = OutputLatency.current()
    var userOffset: Double = 0                     // manual sync trim (, and . keys), seconds; + = visuals later
    private var barShift = 0, phraseShift = 0, lastAlignDrop = -100.0
    private var groove = [Double](repeating: 0, count: 8)
    private var grooveHit = [Int](repeating: Int.min, count: 8)
    private var lastEighth = -1
    private var kicksOnGrid = 0.0
    private var lastRealKick = -100.0
    var syncInfo: String {
        let r = audio.snapshot().referee
        let ref = r.map { String(format: "referee %d reports (%.0f ms) fixes t%d p%d b%d %@", $0.reports, $0.lastMs, $0.tempoFixes, $0.phaseFixes, $0.barFixes, $0.lastAction) } ?? "referee off"
        return String(format: "out %@ %.0f ms · trim %+.0f ms · bar %@ · groove %@ · ", outputLatency.transport, outputLatency.seconds * 1000, userOffset * 1000,
                      barShiftValid ? "on" : "…", kicksOnGrid > 0.55 ? "locked" : "learning") + ref
    }
    private var barShiftValid: Bool { audio.snapshot().barConfidence > 0.15 }
    private(set) var firstReactionHost: Double?   // host time of first frame drawn with live audio
    private(set) var firstSoundHost: Double?

    // Metrics
    let metrics = Metrics()
    var snapTimes: [Double] = []
    var lumLogPath: String?          // --lumlog <file>: per-frame "elapsed phase beatIdx meanLuma kick" for beat-lock proofs
    private var lumBuf = "elapsed phase beatIdx luma kick\n", lumFlushed = 0.0
    var smooth: SmoothProbe?         // --smoothlog <file>: per-frame flicker / motion of the final frame (SmoothProbe)
    var snapDir = URL(fileURLWithPath: NSString(string: "~/.cache/ravelive").expandingTildeInPath)
    var onHUD: ((String) -> Void)?
    private var pendingKickHost: Double = 0
    private var presentDelay: Double = 0.025   // learned draw->photon delay (EMA)
    private var lastKickDrawn = 0

    init?(view: MTKView, audio: AudioEngine) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q; self.audio = audio
        do {
            let lib = try dev.makeLibrary(source: stageShaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain")
            d.fragmentFunction = lib.makeFunction(name: "fmain")
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try dev.makeRenderPipelineState(descriptor: d)
            let tl = try dev.makeLibrary(source: transitionShaderSource, options: nil)
            let td = MTLRenderPipelineDescriptor()
            td.vertexFunction = tl.makeFunction(name: "tvert"); td.fragmentFunction = tl.makeFunction(name: "tmix")
            td.colorAttachments[0].pixelFormat = view.colorPixelFormat
            transitionPipeline = try dev.makeRenderPipelineState(descriptor: td)
        } catch { NSLog("Shader error: \(error)"); return nil }
        visuals = VisualsRenderer(device: dev, pixelFormat: view.colorPixelFormat)
        let pc = QualityTier.active.particlesEffective   // 1M on High; RAVE_PARTICLES overrides
        aurora = AuroraRenderer(device: dev, pixelFormat: view.colorPixelFormat, particles: pc)
        milk = MilkDropRenderer(device: dev, pixelFormat: view.colorPixelFormat, library: MilkDropLibrary())
        super.init()
        milk?.onEvent = { [weak self] e in self?.metrics.event(e, at: CACurrentMediaTime()) }
        metrics.event(String(format: "renderer:t0 host=%.4f", t0), at: t0)     // lets tests line --smoothlog times up with other host-clock logs
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastFrame))
        metrics.frame(interval: now - lastFrame)
        lastFrame = now
        let s = audio.snapshot()
        let host = hostNow()

        // --- auto start / idle
        if s.playing && firstSoundHost == nil { firstSoundHost = host }
        let target: Float = s.silentFor < 10 ? 1 : 0   // 10 s of silence drops to the idle stage
        fade += (target - fade) * min(1, dt * (target > fade ? 6 : 0.5))

        // --- onset envelopes
        let newKick = s.kickCount != lastKick, newSnare = s.snareCount != lastSnare, newHat = s.hatCount != lastHat
        if newKick { kickEnv = 1; lastKick = s.kickCount; pendingKickHost = s.lastKickHostTime }
        if newSnare { snareEnv = 1; lastSnare = s.snareCount }
        if s.hatCount != lastHat { hatEnv = 1; lastHat = s.hatCount }
        kickEnv *= expf(-dt * 9); snareEnv *= expf(-dt * 10); hatEnv *= expf(-dt * 22)
        if pulseIntensity != intensity {
            pulseIntensity = intensity
            let (a, r) = intensity.kickAR
            kickPulse = Pulse(attack: a, release: r); predPulse = Pulse(attack: a, release: r)
        }
        let kickEased = kickPulse.step(newKick, dt: dt), snareEased = snarePulse.step(newSnare, dt: dt), hatEased = hatPulse.step(newHat, dt: dt)

        // --- predicted beat on the *heard* timeline.
        // Beat phase is known on the capture clock. The frame reaches the screen presentDelay from now, and the
        // speakers play captured audio outputLatency later, so evaluate the grid at (now + presentDelay - outputLatency).
        var phase = 0.0, beat: Float = 0
        let locked = s.bpm > 0 && s.confidence > 0.25
        var predictedKick = false
        if locked {
            let heard = host + presentDelay - outputLatency.seconds - userOffset
            let raw = s.beatPhase + (heard - s.phaseHostTime) * s.bpm / 60
            let ahead = floor(raw)
            phase = raw - ahead
            beat = beatPulse(phase: phase, bpm: s.bpm, lead: 0.035, release: intensity.beatRelease)
            // musical beat counter: analyzer beat index, aligned to the detected bar (beat 1 = downbeat)
            // and to the phrase grid (the last drop starts a 16-beat phrase)
            let analyzerBeat = s.beatIndex + Int(ahead)
            let barBeat = ((s.beatInBar + Int(ahead)) % 4 + 4) % 4
            if s.barConfidence > 0.15 { barShift = ((barBeat - analyzerBeat) % 4 + 4) % 4 }
            let musical = analyzerBeat + barShift + phraseShift
            // stable counter: +1 per beat; bar re-alignments only once the analyzer agrees for 8 beats, or on a drop
            let dropAlign = director.dropTime != lastAlignDrop && director.dropTime > 0
            var (stable, jumped) = beatCounter.step(target: musical, phase: phase, adoptNow: dropAlign)
            if dropAlign {
                lastAlignDrop = director.dropTime
                let b = stable - ((stable % 4) + 4) % 4            // drop bar opens a 16-beat phrase
                let add = ((16 - (b % 16)) % 16 + 16) % 16
                phraseShift += add; beatCounter.shift(add); stable += add
            }
            if jumped && !dropAlign { metrics.event("beat:realign \(stable - Int(beatIdx) - 1)", at: now) }
            if !wasLocked {
                // lock (re)acquired: keep the continuous clock where it was, up to whole phrases
                let target = Double(stable) + phase
                clockBase = 16 * ((clock - target) / 16).rounded()
            }
            beatIdx = Float(stable)
            clock = Double(stable) + phase + clockBase
            lastBeatPhase = phase
            // groove template: which 8th-note slots of the bar carry a kick, learned from detected kicks.
            // Firing kicks from the template lands them exactly on the heard beat instead of ~50 ms late.
            let eighth = Int(beatIdx) * 2 + Int(floor((phase + kickLead * s.bpm / 60) * 2))
            if newKick {
                let kh = s.lastKickHostTime
                let kraw = s.beatPhase + (kh - s.phaseHostTime) * s.bpm / 60
                let ke = (Double(beatIdx) + phase + (kraw - raw)) * 2      // the kick's place on the stable grid
                let n = Int(ke.rounded())
                if abs(ke - Double(n)) < 0.3 {
                    let k = ((n % 8) + 8) % 8
                    groove[k] += 0.25 * (1 - groove[k]); grooveHit[k] = n
                    kicksOnGrid += 0.1 * (1 - kicksOnGrid)
                } else { kicksOnGrid *= 0.9 }
            }
            if eighth != lastEighth {
                if lastEighth >= 0 {
                    let chk = eighth - 3, k = ((chk % 8) + 8) % 8       // slot well behind us: was a kick seen there?
                    if grooveHit[k] != chk { groove[k] *= 0.65 }
                    let slot = ((eighth % 8) + 8) % 8
                    if groove[slot] > 0.5 && kicksOnGrid > 0.55 { predictedKick = true }
                }
                lastEighth = eighth
            }
        } else {
            beat = kickEased
            kicksOnGrid *= 0.995
            beatCounter.reset()
            clock += Double(dt) * 2                 // free-runs at 120 BPM, continuing from where the lock left it
        }
        wasLocked = locked
        let predEased = predPulse.step(predictedKick, dt: dt)
        // the template only plays while real kicks are present (breakdowns/builds go quiet instead of ghost-kicking)
        if newKick { lastRealKick = now }
        let grooveLocked = locked && kicksOnGrid > 0.55 && now - lastRealKick < 2.2 * 60 / max(60, s.bpm)
        let kickVisual = grooveLocked ? predEased : kickEased
        let kickEvent = grooveLocked ? predictedKick : newKick

        // --- show director: looks per phrase, build-ups, drops, pyro
        let e = s.energy
        let d = director.step(.init(now: now, dt: dt, energy: e, energyShort: s.energyShort, energyLong: s.energyLong,
                                    kick: newKick, snare: newSnare, beatIndex: Int(beatIdx),
                                    beatLocked: s.bpm > 0 && s.confidence > 0.25, playing: s.playing))
        for ev in director.events.dropFirst(eventsLogged) { metrics.event(ev.1, at: ev.0) }
        eventsLogged = director.events.count

        // --- crowd behaviour follows energy
        let tj: Float = e > 0.65 ? min(1, (e - 0.5) * 2.2) : 0
        jump += (max(tj, d.drop) - jump) * min(1, dt * 2)
        hands += ((e > 0.75 || d.drop > 0.4 || d.build > 0.5 ? 1 : 0.1) - hands) * min(1, dt * 1.5)
        density += ((s.playing ? 0.35 + 0.65 * e : 0.2) - density) * min(1, dt * 0.2)

        // --- strobe + blinder hits share one photosensitivity limiter (<= 3 flashes/s by default)
        let minGap = strobeOverride ? 0.08 : 1.0 / 3.0
        // strobe: Wild = drops + very loud moments; Normal = drops only; Chill = never
        let wantFlash = strobeEnabled && (manualStrobe || (s.playing && intensity != .chill && (d.drop > 0.5 || (intensity == .wild && e > 0.9)) && snareEnv > 0.95))
        let blinderHit = director.takeFlash()
        var blinder = d.blinder
        if (wantFlash || blinderHit) && now - lastFlash >= minGap {
            lastFlash = now; metrics.flash(at: now)
            if !wantFlash { strobeFromBlinder = true } else { strobeFromBlinder = false }
        } else if blinderHit { blinder = min(blinder, 0.5) }   // limiter refused: dim the hit
        // Wild: a hard 45 ms strobe. Normal / Chill: the same limited flashes, eased in and out (no one-frame white)
        let flashOn = now - lastFlash < 0.045 && !strobeFromBlinder
        let flashStart = flashOn && now - lastFlash < Double(dt) + 0.001
        let eased = strobePulse.step(flashStart, dt: dt)
        strobe = intensity == .wild ? (flashOn ? 1 : 0) : eased * 0.7
        if !strobeEnabled { blinder = min(blinder, 0.5) }

        // --- uniforms (visuals get the smoothed snapshot: no frame-to-frame band jitter)
        let vs = smoother.step(s, dt: dt)
        let size = view.drawableSize
        u[0] = Float(size.width); u[1] = Float(size.height); u[2] = Float(now - t0)
        u[3] = vs.energy
        for i in 0..<5 { u[4 + i] = vs.bands[i] }
        let k = intensity.pulse
        u[9] = kickVisual * k; u[10] = snareEased * k; u[11] = hatEased * k
        u[12] = beat * k; u[13] = Float(phase)
        u[14] = strobe; u[15] = blackout ? 1 : 0; u[16] = fade
        u[17] = d.drop; u[18] = stage; u[19] = d.laser
        u[20] = jump; u[21] = hands; u[22] = density; u[23] = d.fire
        u[24] = (kickVisual * e + d.drop * 0.5) * intensity.shake; u[25] = beatIdx; u[26] = stage
        u[27] = forcedLook ?? d.look; u[28] = forcedBeam ?? d.beamProg; u[29] = forcedLaser ?? d.laserProg
        u[30] = d.fireball; u[31] = d.sparks; u[32] = d.co2; u[33] = blinder; u[34] = d.build
        u[35] = d.jetMask; u[36] = d.smoke
        u[38] = Float(intensity.rawValue)
        u[37] = Float(clock)     // continuous beat clock (beats): latency-compensated grid when locked, 120 BPM free-run otherwise; never jumps except on drops

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let dropStarted = director.dropTime != lastDropTime && director.dropTime > 0
        milk?.intensity = intensity.rawValue
        let ctx = SceneCtx(size: size, dt: dt, s: vs, newKick: kickEvent, newHat: newHat, look: d.look, dropStarted: dropStarted, now: now)
        if mode == .show {
            let tbc = clock
            let bps = locked ? s.bpm / 60 : 2.0
            showStep(ctx: ctx, beatClock: tbc, bps: bps, locked: locked, energy: d.drop > 0.5 ? 1 : s.energy, build: d.build)
            if var tr = transition {
                ensureOffscreen(size)
                // monotonic progress: follows the beat clock, but never jumps when the clock re-aligns or the lock drops
                let clockProg = (tbc - tr.startBeat) / tr.beats
                let stepProg = tr.prog + Double(dt) * bps / tr.beats
                tr.prog = min(1, max(tr.prog, abs(clockProg - stepProg) < 0.15 ? clockProg : stepProg))
                transition = tr
                transitionProgress = Float(tr.prog)
                if tr.prog >= 1 {
                    transition = nil
                    encodeScene(showScene, cb: cb, rpd: rpd, ctx: ctx)
                } else if let ta = offA, let tbx = offB {
                    encodeScene(tr.from, cb: cb, rpd: offscreenPass(ta), ctx: ctx)
                    encodeScene(tr.to, cb: cb, rpd: offscreenPass(tbx), ctx: ctx, secondary: true)
                    encodeMix(cb: cb, rpd: rpd, a: ta, b: tbx, prog: Float(tr.prog), type: tr.type, size: size)
                }
            } else {
                encodeScene(showScene, cb: cb, rpd: rpd, ctx: ctx)
                // the next scene already runs offscreen for a bar, so it starts warm (no stale or empty first frames)
                if let up = upcoming, up != showScene, let tb = { ensureOffscreen(size); return offB }() {
                    encodeScene(up, cb: cb, rpd: offscreenPass(tb), ctx: ctx, secondary: true)
                }
            }
        } else if mode == .visuals, let vis = visuals {
            let before = vis.preset
            vis.direct(look: ctx.look, dropStarted: ctx.dropStarted)
            if vis.preset != before { metrics.event("preset->" + VisualsRenderer.presetNames[vis.preset], at: ctx.now) }
            encodeClassic(vis, cb: cb, rpd: rpd, ctx: ctx, bpm: locked ? s.bpm : 120)
        } else {
            if mode == .milkdrop, let m = milk, let ev = m.direct(beat: Int(beatIdx), phase: phase, beatLocked: locked, dropStarted: dropStarted, now: now,
                                                                energy: s.energy, intensity: intensity.rawValue, bpm: s.bpm) {
                metrics.event(ev, at: now)
            }
            encodeScene(mode, cb: cb, rpd: rpd, ctx: ctx)
        }
        lastDropTime = director.dropTime

        // audio->photon latency: the first presented frame after a new kick
        if s.kickCount != lastKickDrawn && pendingKickHost > 0 && s.playing {
            lastKickDrawn = s.kickCount
            let kh = pendingKickHost
            drawable.addPresentedHandler { [weak self] d in
                if d.presentedTime > 0 { self?.metrics.latency(d.presentedTime - kh) }
            }
        }
        if firstReactionHost == nil && s.playing && fade > 0.05 {
            firstReactionHost = host
            if let fs = firstSoundHost { metrics.firstReaction = host - fs }
        }
        cb.addCompletedHandler { [weak self] c in self?.metrics.gpu(c.gpuEndTime - c.gpuStartTime) }
        let drawHost = host
        drawable.addPresentedHandler { [weak self] d in
            guard let self, d.presentedTime > 0 else { return }
            let dd = d.presentedTime - drawHost
            if dd > 0 && dd < 0.2 { self.presentDelay += 0.05 * (dd - self.presentDelay); self.metrics.present(dd) }
        }

        let elapsed = now - t0
        let snapNow = !snapTimes.isEmpty && elapsed >= snapTimes[0]
        if snapNow { snapTimes.removeFirst() }
        // Discrete GPUs (Intel Macs with AMD): drawables are managed, so copy GPU -> CPU before getBytes.
        if (snapNow || lumLogPath != nil) && drawable.texture.storageMode == .managed, let b = cb.makeBlitCommandEncoder() {
            b.synchronize(resource: drawable.texture); b.endEncoding()
        }
        // Shader Lab errors + Tweak panel are for the performer: drawn after Syphon / the output display take the frame
        let labOverlay: ((MTLRenderCommandEncoder, CGSize) -> Void)? = mode == .visuals ? { [weak self] e, sz in
            guard let v = self?.visuals else { return }
            v.lab.drawOverlays(e, size: sz, device: v.device, pixelFormat: drawable.texture.pixelFormat)
        } : nil
        if let fo = frameOutput { fo.process(cb: cb, texture: drawable.texture, overlay: labOverlay) }
        else if let ov = labOverlay { FrameOutput.drawOverlay(ov, cb: cb, on: drawable.texture) }
        if let sp = smooth { sp.encode(cb: cb, source: drawable.texture, meta: probeMeta(elapsed: elapsed, dt: dt, phase: phase, locked: locked, kick: kickVisual, d: d)) }
        cb.present(drawable)
        cb.commit()
        if snapNow {
            cb.waitUntilCompleted()
            saveSnapshot(drawable.texture, name: String(format: "snap_%05.1f.png", elapsed))
        }
        if let path = lumLogPath {          // beat-lock probe (test only): mean frame luminance next to the beat phase this frame was drawn with
            cb.waitUntilCompleted()
            let tex = drawable.texture, w = tex.width, h = tex.height
            var px = [UInt8](repeating: 0, count: w * 4)
            var sum = 0.0, n = 0.0
            for y in stride(from: 0, to: h, by: 24) {
                tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0)
                for x in stride(from: 0, to: w, by: 16) { sum += 0.114 * Double(px[x * 4]) + 0.587 * Double(px[x * 4 + 1]) + 0.299 * Double(px[x * 4 + 2]); n += 1 }
            }
            lumBuf += String(format: "%.4f %.4f %d %.4f %.4f\n", elapsed, phase, Int(beatIdx), sum / max(n, 1) / 255, kickVisual)
            if elapsed - lumFlushed > 2 { lumFlushed = elapsed; try? lumBuf.write(toFile: path, atomically: false, encoding: .utf8) }
        }
        metrics.state = (mode == .show ? "show:\(showScene.title) " : "") + (mode == .milkdrop ? "milkdrop:\(milk?.currentName ?? "") " : "") + (mode == .aurora ? "aurora hands=\(camera?.hands.count ?? 0) " : visualsMode ? "visuals:\(visuals?.preset ?? -1) " : "stage ") + String(format: "bpm=%.1f conf=%.2f e=%.2f look=%.0f beam=%.0f laser=%.0f build=%.2f drop=%.2f fade=%.2f src=%@ gaps=%d",
                               s.bpm, s.confidence, e, d.look, d.beamProg, d.laserProg, d.build, d.drop, fade, s.source, s.droppedGaps)
        if hudVisible && Int(elapsed * 4) != Int((elapsed - Double(dt)) * 4) {
            let m = metrics.summary(recent: 600)
            let showName = mode == .show ? "SHOW → " + (transition != nil ? "transition to " : "") + showScene.title + (showScene == .visuals ? " " + VisualsRenderer.presetNames[visuals?.preset ?? 0] : "") : ""
            let milkName = "MILKDROP: " + (milk?.ready == true ? (milk?.currentName ?? "") + (milk?.director.locked == true ? " (locked)" : "") : milk?.lib == nil ? "engine missing" : "no presets")
            let modeName = mode == .milkdrop ? milkName : mode == .show ? showName + (showScene == .milkdrop ? " " + (milk?.currentName ?? "") : "") : mode == .aurora ? "AURORA" + (camera?.running == true ? " · camera on (\(camera?.hands.count ?? 0) hands)" : " · drag the mouse, C = camera") : visualsMode ? "VISUALS: " + VisualsRenderer.presetNames[(visuals?.preset ?? 0) % VisualsRenderer.count] + ((visuals?.autoCycle ?? true) ? " (auto)" : "") : "STAGE"
            onHUD?(modeName + "  ·  " + String(format: "%@  ·  %.0f BPM  conf %.0f%%  ·  %.0f fps  p95 %.1f ms  ·  latency p50 %.0f ms%@",
                          s.playing ? "LIVE" : (fade > 0.05 ? "LIVE (quiet)" : "WAITING FOR MUSIC"),
                          s.bpm, s.confidence * 100, m.fps, m.frameP95 * 1000, m.latP50 * 1000,
                          strobeOverride ? "  ·  ⚠️ STROBE LIMIT OFF" : (strobeEnabled ? "" : "  ·  strobe off"))
                   + "  ·  \(intensity.title) (I)  ·  beat \(Int(beatIdx) % 4 + 1)/4  ·  " + syncInfo)
        }
    }

    /// What is on screen right now, for the smoothness probe's log.
    private func probeMeta(elapsed: Double, dt: Float, phase: Double, locked: Bool, kick: Float, d: ShowDirector.Output) -> SmoothProbe.Meta {
        func name(_ m: Mode) -> String {
            switch m {
            case .visuals: return visuals?.currentName ?? "?"
            case .milkdrop: return milk?.currentName ?? "?"
            case .aurora: return "sym\(aurora?.symmetry ?? 0)"
            default: return "stage\(Int(stage)) look\(Int(forcedLook ?? d.look))"
            }
        }
        let scene = mode == .show ? showScene : mode
        var trans = "-"
        if mode == .show, let tr = transition {
            trans = String(format: "%@:%@>%@:%.3f", Self.transitionNames[tr.type].replacingOccurrences(of: " ", with: "_"), tr.from.probeName, tr.to.probeName, transitionProgress)
        }
        return .init(t: elapsed, dt: dt, phase: phase, beat: Int(beatIdx), locked: locked, kick: kick, drop: d.drop, build: d.build,
                     mode: mode.probeName, scene: scene.probeName, preset: name(scene), trans: trans)
    }

    struct SceneCtx { var size: CGSize; var dt: Float; var s: AudioSnapshot; var newKick: Bool; var newHat: Bool; var look: Float; var dropStarted: Bool; var now: Double }

    /// Render one scene into a pass (the drawable, or an offscreen texture during SHOW transitions).
    private func encodeScene(_ m: Mode, cb: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, ctx: SceneCtx, secondary: Bool = false) {
        switch m {
        case .aurora:
            guard let au = aurora else { return }
            au.pointers = secondary && !auroraPointersTaken ? au.pointers : collectPointers(dt: ctx.dt, t: ctx.now - t0)
            if let mk = camera?.takeMask() { au.updateMask(mk); au.maskActive = true } else if camera?.running != true { au.maskActive = false }
            au.encode(cb: cb, rpd: rpd, size: ctx.size, dt: ctx.dt, s: ctx.s, u: u, newKick: ctx.newKick, newHat: ctx.newHat,
                      dropStarted: ctx.dropStarted, strobe: u[14], blackout: blackout, fade: u[16])
        case .visuals:
            guard let vis = visuals else { return }
            vis.encode(cb: cb, rpd: rpd, size: ctx.size, dt: ctx.dt, s: ctx.s, u: u, input: visualsInput(dt: ctx.dt, now: ctx.now))
        case .milkdrop:
            milk?.encode(cb: cb, rpd: rpd, size: ctx.size, u: u, playing: ctx.s.playing)
        default:
            if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentBytes(u, length: u.count * 4, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
    }
    private var auroraPointersTaken = false

    /// Mix two rendered scenes with the transition shader. Drop cuts (type 0) flash less on Normal / Chill.
    private func encodeMix(cb: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, a: MTLTexture, b: MTLTexture, prog: Float, type: Int, size: CGSize) {
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let flash: Float = [0.3, 0.55, 1.0][intensity.rawValue]
        var tu: [Float] = [max(0, prog), Float(type), u[2], Float(size.width / size.height), u[12], u[2] * 0.03, flash]
        enc.setRenderPipelineState(transitionPipeline)
        enc.setFragmentTexture(a, index: 0); enc.setFragmentTexture(b, index: 1)
        enc.setFragmentBytes(&tu, length: tu.count * 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // ---- Classic mode: preset changes crossfade (both presets keep running, each in its own feedback slot)
    private struct ClassicFade { var from: Int; var fromSlot: Int; var start: Double; var seconds: Double; var frozen = false }
    private var classicFade: ClassicFade?
    private var classicShown = -1
    private func encodeClassic(_ vis: VisualsRenderer, cb: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, ctx: SceneCtx, bpm: Double) {
        if vis.preset != classicShown {
            if classicShown >= 0 && classicShown < VisualsRenderer.count {
                // automatic changes blend over a bar, picks by hand over a third of a second
                classicFade = ClassicFade(from: classicShown, fromSlot: vis.slot, start: ctx.now, seconds: vis.autoCycle ? max(0.9, 240 / max(60, bpm)) : 0.35)
                vis.slot = 1 - vis.slot
            }
            classicShown = vis.preset
        }
        guard var f = classicFade, let ta = { ensureOffscreen(ctx.size); return offA }(), let tb = offB else {
            encodeScene(.visuals, cb: cb, rpd: rpd, ctx: ctx); return
        }
        let p = (ctx.now - f.start) / f.seconds
        if p >= 1 || f.from >= VisualsRenderer.count { classicFade = nil; encodeScene(.visuals, cb: cb, rpd: rpd, ctx: ctx); return }
        let to = vis.preset, toSlot = vis.slot
        // Coral / Pond / Life share one simulation texture: between two of them the outgoing one is held as a still
        let bothSim = VisualsRenderer.simPresets.contains(f.from) && VisualsRenderer.simPresets.contains(to)
        if !(bothSim && f.frozen) {
            vis.preset = f.from; vis.slot = f.fromSlot
            encodeScene(.visuals, cb: cb, rpd: offscreenPass(ta), ctx: ctx)
            vis.preset = to; vis.slot = toSlot
            if bothSim { f.frozen = true; classicFade = f }
        }
        encodeScene(.visuals, cb: cb, rpd: offscreenPass(tb), ctx: ctx)
        encodeMix(cb: cb, rpd: rpd, a: ta, b: tb, prog: Float(p), type: 7, size: ctx.size)
    }

    // ---- SHOW: one continuous set that moves between Stage, Classic and AURORA on the beat
    struct Transition { var from: Mode; var to: Mode; var type: Int; var startBeat: Double; var beats: Double; var prog = 0.0 }
    private(set) var showScene: Mode = .aurora
    private var transition: Transition?
    private var transitionProgress: Float = 0
    private var lastBar = -1
    private var sceneBeats = 0.0               // beats the SHOW scene has been on (accumulated, so clock jumps can't cut a scene short)
    private var upcoming: Mode?                // next SHOW scene: picked a bar early and rendered offscreen until the transition
    private var upcomingBeats = 0.0
    private var upcomingForDrop = false
    private var dropScenes = 0
    private var showRng: UInt64 = 0x5EED
    private var offA: MTLTexture?, offB: MTLTexture?
    static let transitionNames = ["flash cut", "iris", "liquid melt", "zoom punch", "glitch", "pixel dissolve", "spin kaleido", "crossfade"]
    private func srand(_ n: Int) -> Int { showRng ^= showRng << 13; showRng ^= showRng >> 7; showRng ^= showRng << 17; return Int(showRng % UInt64(n)) }

    /// SHOW playlist: a shuffle bag of slots across all renderers. Every classic preset plays once,
    /// AURORA 3x and Stage 2x per cycle (each visit with a new colour/symmetry variant), and the same
    /// renderer never plays twice in a row unless nothing else is left.
    private var slots: [Mode] = []
    private func nextSlot(energy: Float) -> Mode {
        // refill when empty, or when only the scene on screen is left (a renderer can't blend into itself)
        if slots.isEmpty || !slots.contains(where: { $0 != showScene }) {
            var bag = [Mode](repeating: .visuals, count: 10) + [.aurora, .aurora, .aurora, .stage, .stage]
            if milk?.ready == true && showMilkDrop { bag += [.milkdrop, .milkdrop, .milkdrop] }
            slots = bag.shuffled() + slots
        }
        if let i = slots.lastIndex(where: { $0 != showScene }) { return slots.remove(at: i) }
        return slots.removeLast()
    }

    /// Set the next scene up (preset, variant, MilkDrop load) so it can run offscreen before it is shown.
    private func prepare(_ to: Mode, loud: Bool) {
        switch to {
        case .visuals:
            if let v = visuals {
                v.autoCycle = false
                v.preset = v.nextFromBag(prefer: loud ? VisualsRenderer.loudPresets : VisualsRenderer.calmPresets)
                v.newVariant()
            }
        case .aurora: aurora?.newVariant(seed: srand(1000))
        case .stage: stage = Float(srand(4))
        case .milkdrop: milk?.loadNext(loud: loud, smooth: false, blendSeconds: 0, why: "show")
        default: break
        }
    }

    private func startTransition(to: Mode, type: Int, beats: Double, at beat: Double, ctx: SceneCtx) {
        transition = Transition(from: showScene, to: to, type: type, startBeat: beat, beats: beats)
        metrics.event("show:\(showScene.title)->\(to.title) [\(Self.transitionNames[type]) \(Int(beats))b]" + (to == .visuals ? " " + VisualsRenderer.presetNames[visuals?.preset ?? 0] + " pal\(visuals?.paletteIndex ?? 0)" : to == .aurora ? " sym\(aurora?.symmetry ?? 0)" : ""), at: ctx.now)
        showScene = to
        sceneBeats = 0
        lastTransitionType = type
    }
    private var lastTransitionType = -1
    /// SHOW also rotates through MilkDrop presets when the engine and presets are there.
    var showMilkDrop = true

    private func showStep(ctx: SceneCtx, beatClock: Double, bps: Double, locked: Bool, energy: Float, build: Float) {
        sceneBeats += Double(ctx.dt) * bps
        if upcoming != nil { upcomingBeats += Double(ctx.dt) * bps }
        // drops: cut exactly on the drop kick to a big scene (fresh variant each time; warm when a build announced it)
        if ctx.dropStarted {
            dropScenes += 1
            var target: Mode
            if let up = upcoming, upcomingForDrop, up != showScene { target = up } else {
                target = [.stage, .aurora, .visuals][dropScenes % 3]
                if target == showScene { dropScenes += 1; target = [.stage, .aurora, .visuals][dropScenes % 3] }
                prepare(target, loud: true)
            }
            upcoming = nil
            startTransition(to: target, type: 0, beats: 1, at: beatClock, ctx: ctx)
            return
        }
        guard transition == nil else { return }
        // a build is under way: get the drop scene ready offscreen
        if build > 0.4 && !upcomingForDrop {
            var target: Mode = [.stage, .aurora, .visuals][(dropScenes + 1) % 3]
            if target == showScene { dropScenes += 1; target = [.stage, .aurora, .visuals][(dropScenes + 1) % 3] }
            prepare(target, loud: true)
            upcoming = target; upcomingBeats = 0; upcomingForDrop = true
            metrics.event("show:prewarm(drop) \(target.title)", at: ctx.now)
        }
        let bar = Int(floor(beatClock / 4))
        guard bar != lastBar else { return }
        lastBar = bar
        // loud music changes every 16 beats, calm every 32
        let hold: Double = intensity == .wild && energy > 0.6 ? 16 : (intensity == .chill ? 64 : 32)
        // one bar before the change: pick the next scene and start it offscreen
        if upcoming == nil && sceneBeats >= hold - 4 - 0.01 {
            let pick = nextSlot(energy: energy)
            prepare(pick, loud: energy > 0.6)
            upcoming = pick; upcomingBeats = 0; upcomingForDrop = false
        }
        guard sceneBeats >= hold - 0.01, let next = upcoming, next != showScene, upcomingBeats >= 3 else { return }
        // glitch (4) and pixel dissolve (5) are the harsh ones: Wild only
        let pool = intensity == .wild ? [1, 2, 3, 4, 5, 6] : [1, 2, 3, 6]
        var type = pool[srand(pool.count)]; if type == lastTransitionType { type = pool[(pool.firstIndex(of: type)! + 1) % pool.count] }
        let beats: Double = intensity == .wild && energy > 0.7 ? [1, 2, 2][srand(3)] : [4, 4, 8][srand(3)]
        upcoming = nil; upcomingForDrop = false
        startTransition(to: next, type: type, beats: beats, at: Double(bar * 4), ctx: ctx)
    }

    private func ensureOffscreen(_ size: CGSize) {
        let w = max(16, Int(size.width)), h = max(16, Int(size.height))
        if offA?.width == w && offA?.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        offA = device.makeTexture(descriptor: d); offB = device.makeTexture(descriptor: d)
    }
    private func offscreenPass(_ t: MTLTexture) -> MTLRenderPassDescriptor {
        let r = MTLRenderPassDescriptor()
        r.colorAttachments[0].texture = t; r.colorAttachments[0].loadAction = .clear
        r.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); r.colorAttachments[0].storeAction = .store
        return r
    }

    /// Mouse + camera hands (+ optional scripted fake hands for tests) as fluid pointers.
    private func collectPointers(dt: Float, t: Double) -> [AuroraRenderer.Pointer] {
        var out: [AuroraRenderer.Pointer] = []
        if let m = mousePointer { out.append(m); mousePointer?.vel = .zero; mousePointer?.burst = false }
        let hp = handList(t: t)
        for (i, h) in hp.enumerated() {
            let prev = i < handPrev.count ? handPrev[i] : h.0
            let v = dt > 0 ? (h.0 - prev) / max(dt, 1e-3) * 0.12 : .zero
            let wasPinch = i < pinchPrev.count ? pinchPrev[i] : false
            out.append(.init(pos: h.0, vel: v, down: true, burst: h.1 && !wasPinch))
        }
        handPrev = hp.map { $0.0 }; pinchPrev = hp.map { $0.1 }
        return out
    }

    /// Camera hands, or the scripted fake hands (`--fakehands`, optionally from `--fakehands-from <s>`).
    private func handList(t: Double) -> [(SIMD2<Float>, Bool)] {
        if fakeHands {
            guard t >= fakeHandsFrom else { return [] }
            let a = Float(t - fakeHandsFrom) * 1.3
            return [(SIMD2<Float>(0.5 + 0.25 * cos(a), 0.5 + 0.3 * sin(a * 1.7)), Int(t - fakeHandsFrom) % 6 == 0),
                    (SIMD2<Float>(0.5 - 0.25 * cos(a * 0.8), 0.5 + 0.25 * sin(a)), false)]
        }
        return (camera?.hands ?? []).map { ($0.pos, $0.pinch) }
    }

    // ---- pointer input for the Classic visuals (mouse + camera hands): smoothed positions, velocity, click ring
    private var vClicks: [(pos: SIMD2<Float>, time: Double)] = []
    private var vSmooth: [(pos: SIMD2<Float>, vel: SIMD2<Float>)] = []
    private var vPinchPrev: [Bool] = []
    private var vLastMouse = -100.0
    private var vFrameTime = -1.0
    private var vCached = VisualsRenderer.Input()
    /// Called from the view's mouse handler (main thread) so clicks are never lost between frames.
    func pointerEvent(pos: SIMD2<Float>, down: Bool, click: Bool) {
        let now = CACurrentMediaTime()
        vLastMouse = now
        if click { vClicks.append((pos, now)); if vClicks.count > 8 { vClicks.removeFirst() } }
    }
    private func visualsInput(dt: Float, now: Double) -> VisualsRenderer.Input {
        if now == vFrameTime { return vCached }
        vFrameTime = now
        var raw: [(SIMD2<Float>, Float)] = []
        if fakeMouseFrom >= 0, now - t0 >= fakeMouseFrom {         // scripted mouse for headless tests: 4 s loop = 2 s drag (click at start) + 2 s hover
            let tt = Float(now - t0 - fakeMouseFrom), ph = tt.truncatingRemainder(dividingBy: 4)
            let pos = SIMD2<Float>(0.5 + 0.3 * sin(tt * 0.9), 0.5 + 0.25 * cos(tt * 1.3))
            let wasDown = mousePointer?.down ?? false
            mousePointer = .init(pos: pos, vel: .zero, down: ph < 2, burst: false)
            vLastMouse = now
            if ph < 2 && !wasDown { vClicks.append((pos, now)) }
        }
        if let m = mousePointer {
            let idle = Float(now - vLastMouse)
            let s: Float = m.down ? 1 : 0.5 * max(0, min(1, (4 - idle) / 2.5))     // hover fades out when the mouse rests
            if s > 0.01 { raw.append((m.pos, s)) }
        }
        let hp = handList(t: now - t0)
        for h in hp { raw.append((h.0, 1)) }
        // smoothing + velocity (0..1 units per second)
        var next: [(pos: SIMD2<Float>, vel: SIMD2<Float>)] = []
        for (i, r) in raw.enumerated() {
            if i < vSmooth.count {
                let p0 = vSmooth[i].pos
                let p1 = p0 + (r.0 - p0) * min(1, dt * 14)
                let v1 = dt > 0 ? (p1 - p0) / max(dt, 1e-3) : .zero
                next.append((p1, vSmooth[i].vel + (v1 - vSmooth[i].vel) * 0.35))
            } else { next.append((r.0, .zero)) }
        }
        vSmooth = next
        // hand pinch = click
        let mouseCount = raw.count - hp.count
        for (i, h) in hp.enumerated() {
            let was = i < vPinchPrev.count ? vPinchPrev[i] : false
            if h.1 && !was { vClicks.append((h.0, now)); if vClicks.count > 8 { vClicks.removeFirst() } }
        }
        vPinchPrev = hp.map { $0.1 }
        _ = mouseCount
        vClicks.removeAll { now - $0.time > 10 }
        var inp = VisualsRenderer.Input()
        for (i, r) in raw.enumerated() { inp.pointers.append(.init(pos: vSmooth[i].pos, vel: vSmooth[i].vel, strength: r.1)) }
        inp.clicks = vClicks.reversed().prefix(4).map { ($0.pos, Float(now - $0.time)) }
        vCached = inp
        return inp
    }

    private func saveSnapshot(_ tex: MTLTexture, name: String) {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA -> RGBA
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: snapDir.appendingPathComponent(name))
    }
}

/// Frame / GPU / latency statistics, dumped as JSON for acceptance checks.
final class Metrics: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [Double] = []
    private var gpuTimes: [Double] = []
    private var latencies: [Double] = []
    private var flashes: [Double] = []
    var firstReaction: Double?
    var state = ""
    var sync = ""
    let started = Date()

    func frame(interval: Double) { lock.lock(); intervals.append(interval); if intervals.count > 200_000 { intervals.removeFirst(100_000) }; lock.unlock() }
    func gpu(_ t: Double) { lock.lock(); gpuTimes.append(t); if gpuTimes.count > 200_000 { gpuTimes.removeFirst(100_000) }; lock.unlock() }
    func latency(_ t: Double) { lock.lock(); if t > 0 && t < 1 { latencies.append(t) }; lock.unlock() }
    private var presents: [Double] = []
    func present(_ t: Double) { lock.lock(); presents.append(t); if presents.count > 100_000 { presents.removeFirst(50_000) }; lock.unlock() }
    func presentP50() -> Double { lock.lock(); defer { lock.unlock() }; let a = presents.sorted(); return a.isEmpty ? .nan : a[a.count / 2] }
    private var events: [[String: Any]] = []
    func event(_ name: String, at t: Double) { lock.lock(); events.append(["t": t - CACurrentMediaTime() + Date().timeIntervalSince(started), "event": name]); lock.unlock() }
    func flash(at t: Double) { lock.lock(); flashes.append(t); lock.unlock() }

    struct Summary { var fps: Double; var frameP50: Double; var frameP95: Double; var frameP99: Double; var gpuP95: Double; var latP50: Double; var latP95: Double; var maxFlashesPerSec: Int; var frames: Int; var latN: Int }

    func summary(recent: Int? = nil) -> Summary {
        lock.lock(); defer { lock.unlock() }
        let intervals = recent.map { Array(self.intervals.suffix($0)) } ?? self.intervals
        let gpuTimes = recent.map { Array(self.gpuTimes.suffix($0)) } ?? self.gpuTimes
        let latencies = recent.map { Array(self.latencies.suffix($0)) } ?? self.latencies
        func pct(_ a: [Double], _ q: Double) -> Double { a.isEmpty ? .nan : a.sorted()[min(a.count - 1, Int(Double(a.count) * q))] }
        let recent = Array(intervals.suffix(120))
        let fps = recent.isEmpty ? 0 : Double(recent.count) / recent.reduce(0, +)
        let iv = Array(intervals.dropFirst(30))
        var maxF = 0
        for (i, f) in flashes.enumerated() { maxF = max(maxF, flashes[i...].prefix { $0 - f < 1.0 }.count) }
        return Summary(fps: fps, frameP50: pct(iv, 0.5), frameP95: pct(iv, 0.95), frameP99: pct(iv, 0.99),
                       gpuP95: pct(gpuTimes, 0.95), latP50: pct(latencies, 0.5), latP95: pct(latencies, 0.95),
                       maxFlashesPerSec: maxF, frames: intervals.count, latN: latencies.count)
    }

    func dump(to url: URL) {
        let s = summary()
        func j(_ v: Double) -> Any { v.isFinite ? v : NSNull() }
        let d: [String: Any] = [
            "elapsed_s": Date().timeIntervalSince(started), "frames": s.frames, "fps_recent": j(s.fps),
            "frame_interval_ms": ["p50": j(s.frameP50 * 1000), "p95": j(s.frameP95 * 1000), "p99": j(s.frameP99 * 1000)],
            "gpu_ms_p95": j(s.gpuP95 * 1000),
            "audio_capture_to_photon_ms": ["p50": j(s.latP50 * 1000), "p95": j(s.latP95 * 1000), "n": s.latN],
            "first_reaction_after_sound_ms": firstReaction.map { $0 * 1000 } ?? NSNull(),
            "max_strobe_flashes_in_1s": s.maxFlashesPerSec,
            "display": r_displayInfo,
            "sync": sync,
            "draw_to_photon_ms_p50": j(presentP50() * 1000),
            "events": { lock.lock(); defer { lock.unlock() }; return events }(), "state": state,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }
}
