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
    private var kickEnv: Float = 0, snareEnv: Float = 0, hatEnv: Float = 0
    private var lastKick = 0, lastSnare = 0, lastHat = 0
    private var fade: Float = 0
    private var strobe: Float = 0
    private var lastFlash: Double = 0
    let director = ShowDirector()
    /// How hard the show hits. Normal (default) keeps it on beat without being overwhelming.
    enum Intensity: Int, CaseIterable { case chill, normal, wild
        var title: String { ["Chill", "Normal", "Wild"][rawValue] }
        var pulse: Float { [0.45, 0.7, 1.0][rawValue] }     // beat/kick flash strength
        var shake: Float { [0.0, 0.4, 1.0][rawValue] }      // camera shake on hits
    }
    var intensity: Intensity = .normal
    enum Mode: Int, CaseIterable { case show, stage, visuals, aurora
        var title: String { ["SHOW (auto)", "Stage", "Classic Visuals", "AURORA"][rawValue] } }
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
    private var lastDropTime = -100.0
    private var eventsLogged = 0
    private var strobeFromBlinder = false
    var forcedLook: Float?, forcedBeam: Float?, forcedLaser: Float?
    private var jump: Float = 0, hands: Float = 0, density: Float = 0.3
    private var lowSince: Double = 0
    private var beatIdx: Float = 0
    private var lastBeatPhase: Double = 0
    var outputLatency = OutputLatency.current()
    var userOffset: Double = 0                     // manual sync trim (, and . keys), seconds; + = visuals later
    private var barShift = 0, phraseShift = 0, lastAlignDrop = -100.0
    private var groove = [Double](repeating: 0, count: 8)
    private var grooveHit = [Int](repeating: Int.min, count: 8)
    private var lastEighth = -1
    private var kicksOnGrid = 0.0
    private var predKickEnv: Float = 0
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
        let pc = Int(ProcessInfo.processInfo.environment["RAVE_PARTICLES"] ?? "") ?? 1_000_000
        aurora = AuroraRenderer(device: dev, pixelFormat: view.colorPixelFormat, particles: pc)
        super.init()
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
            beat = expf(-Float(phase) * 7)
            // musical beat counter: analyzer beat index, aligned to the detected bar (beat 1 = downbeat)
            // and to the phrase grid (the last drop starts a 16-beat phrase)
            let analyzerBeat = s.beatIndex + Int(ahead)
            let barBeat = ((s.beatInBar + Int(ahead)) % 4 + 4) % 4
            if s.barConfidence > 0.15 { barShift = ((barBeat - analyzerBeat) % 4 + 4) % 4 }
            let musical = analyzerBeat + barShift + phraseShift
            if director.dropTime != lastAlignDrop && director.dropTime > 0 {
                lastAlignDrop = director.dropTime
                let b = musical - (musical % 4)            // drop bar
                phraseShift += ((16 - (b % 16)) % 16)
            }
            let newIdx = Float(analyzerBeat + barShift + phraseShift)
            let jump = Double(newIdx - beatIdx)
            if abs(jump) >= 2 { sceneStartBeat += jump }      // re-alignment, not elapsed time: keep scene hold intact
            beatIdx = newIdx
            lastBeatPhase = phase
            // groove template: which 8th-note slots of the bar carry a kick, learned from detected kicks.
            // Firing kicks from the template lands them exactly on the heard beat instead of ~50 ms late.
            let eighth = Int(beatIdx) * 2 + Int(phase * 2)
            if newKick {
                let kh = s.lastKickHostTime
                let kraw = s.beatPhase + (kh - s.phaseHostTime) * s.bpm / 60
                let ke = (Double(s.beatIndex + barShift + phraseShift) + kraw) * 2
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
                    if groove[slot] > 0.5 && kicksOnGrid > 0.55 { predictedKick = true; predKickEnv = 1 }
                }
                lastEighth = eighth
            }
        } else {
            beat = kickEnv
            kicksOnGrid *= 0.995
        }
        predKickEnv *= expf(-dt * 9)
        // the template only plays while real kicks are present (breakdowns/builds go quiet instead of ghost-kicking)
        if newKick { lastRealKick = now }
        let grooveLocked = locked && kicksOnGrid > 0.55 && now - lastRealKick < 2.2 * 60 / max(60, s.bpm)
        let kickVisual = grooveLocked ? predKickEnv : kickEnv
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
        strobe = now - lastFlash < 0.045 && !strobeFromBlinder ? 1 : 0
        if !strobeEnabled { blinder = min(blinder, 0.5) }

        // --- uniforms
        let size = view.drawableSize
        u[0] = Float(size.width); u[1] = Float(size.height); u[2] = Float(now - t0)
        u[3] = e
        for i in 0..<5 { u[4 + i] = s.bands[i] }
        let k = intensity.pulse
        u[9] = kickVisual * k; u[10] = snareEnv * k; u[11] = hatEnv * k
        u[12] = beat * k; u[13] = Float(phase)
        u[14] = strobe; u[15] = blackout ? 1 : 0; u[16] = fade
        u[17] = d.drop; u[18] = stage; u[19] = d.laser
        u[20] = jump; u[21] = hands; u[22] = density; u[23] = d.fire
        u[24] = (kickVisual * e + d.drop * 0.5) * intensity.shake; u[25] = beatIdx; u[26] = stage
        u[27] = forcedLook ?? d.look; u[28] = forcedBeam ?? d.beamProg; u[29] = forcedLaser ?? d.laserProg
        u[30] = d.fireball; u[31] = d.sparks; u[32] = d.co2; u[33] = blinder; u[34] = d.build
        u[35] = d.jetMask; u[36] = d.smoke
        u[37] = Float(locked ? Double(beatIdx) + phase : (now - t0) * 2.0)     // continuous beat clock (beats): latency-compensated grid when locked, 120 BPM free-run otherwise

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let dropStarted = director.dropTime != lastDropTime && director.dropTime > 0
        let ctx = SceneCtx(size: size, dt: dt, s: s, newKick: kickEvent, newHat: newHat, look: d.look, dropStarted: dropStarted, now: now)
        if mode == .show {
            let tbc = (s.bpm > 0 && s.confidence > 0.25) ? Double(beatIdx) + phase : (now - t0) * 2.0
            showStep(ctx: ctx, beatClock: tbc, locked: s.bpm > 0 && s.confidence > 0.25, energy: d.drop > 0.5 ? 1 : s.energy)
            if let tr = transition {
                ensureOffscreen(size)
                let prog = Float((tbc - tr.startBeat) / tr.beats)
                if prog >= 1 {
                    transition = nil
                    encodeScene(showScene, cb: cb, rpd: rpd, ctx: ctx)
                } else if let ta = offA, let tbx = offB {
                    encodeScene(tr.from, cb: cb, rpd: offscreenPass(ta), ctx: ctx)
                    encodeScene(tr.to, cb: cb, rpd: offscreenPass(tbx), ctx: ctx, secondary: true)
                    if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                        var tu: [Float] = [max(0, prog), Float(tr.type), u[2], Float(size.width / size.height), u[12], u[2] * 0.03]
                        enc.setRenderPipelineState(transitionPipeline)
                        enc.setFragmentTexture(ta, index: 0); enc.setFragmentTexture(tbx, index: 1)
                        enc.setFragmentBytes(&tu, length: tu.count * 4, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        enc.endEncoding()
                    }
                }
            } else {
                encodeScene(showScene, cb: cb, rpd: rpd, ctx: ctx)
            }
        } else {
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
        frameOutput?.process(cb: cb, texture: drawable.texture)
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
        metrics.state = (mode == .show ? "show:\(showScene.title) " : "") + (mode == .aurora ? "aurora hands=\(camera?.hands.count ?? 0) " : visualsMode ? "visuals:\(visuals?.preset ?? -1) " : "stage ") + String(format: "bpm=%.1f conf=%.2f e=%.2f look=%.0f beam=%.0f laser=%.0f build=%.2f drop=%.2f fade=%.2f src=%@ gaps=%d",
                               s.bpm, s.confidence, e, d.look, d.beamProg, d.laserProg, d.build, d.drop, fade, s.source, s.droppedGaps)
        if hudVisible && Int(elapsed * 4) != Int((elapsed - Double(dt)) * 4) {
            let m = metrics.summary(recent: 600)
            let showName = mode == .show ? "SHOW → " + (transition != nil ? "transition to " : "") + showScene.title + (showScene == .visuals ? " " + VisualsRenderer.presetNames[visuals?.preset ?? 0] : "") : ""
            let modeName = mode == .show ? showName : mode == .aurora ? "AURORA" + (camera?.running == true ? " · camera on (\(camera?.hands.count ?? 0) hands)" : " · drag the mouse, C = camera") : visualsMode ? "VISUALS: " + VisualsRenderer.presetNames[(visuals?.preset ?? 0) % VisualsRenderer.count] + ((visuals?.autoCycle ?? true) ? " (auto)" : "") : "STAGE"
            onHUD?(modeName + "  ·  " + String(format: "%@  ·  %.0f BPM  conf %.0f%%  ·  %.0f fps  p95 %.1f ms  ·  latency p50 %.0f ms%@",
                          s.playing ? "LIVE" : (fade > 0.05 ? "LIVE (quiet)" : "WAITING FOR MUSIC"),
                          s.bpm, s.confidence * 100, m.fps, m.frameP95 * 1000, m.latP50 * 1000,
                          strobeOverride ? "  ·  ⚠️ STROBE LIMIT OFF" : (strobeEnabled ? "" : "  ·  strobe off"))
                   + "  ·  \(intensity.title) (I)  ·  beat \(Int(beatIdx) % 4 + 1)/4  ·  " + syncInfo)
        }
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
            if mode != .show {
                let before = vis.preset
                vis.direct(look: ctx.look, dropStarted: ctx.dropStarted)
                if vis.preset != before { metrics.event("preset->" + VisualsRenderer.presetNames[vis.preset], at: ctx.now) }
            }
            vis.encode(cb: cb, rpd: rpd, size: ctx.size, dt: ctx.dt, s: ctx.s, u: u, input: visualsInput(dt: ctx.dt, now: ctx.now))
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

    // ---- SHOW: one continuous set that moves between Stage, Classic and AURORA on the beat
    struct Transition { var from: Mode; var to: Mode; var type: Int; var startBeat: Double; var beats: Double }
    private(set) var showScene: Mode = .aurora
    private var transition: Transition?
    private var sceneStartBeat = 0.0
    private var lastBar = -1
    private var dropScenes = 0
    private var showRng: UInt64 = 0x5EED
    private var offA: MTLTexture?, offB: MTLTexture?
    static let transitionNames = ["flash cut", "iris", "liquid melt", "zoom punch", "glitch", "pixel dissolve", "spin kaleido"]
    private func srand(_ n: Int) -> Int { showRng ^= showRng << 13; showRng ^= showRng >> 7; showRng ^= showRng << 17; return Int(showRng % UInt64(n)) }

    /// SHOW playlist: a shuffle bag of slots across all renderers. Every classic preset plays once,
    /// AURORA 3x and Stage 2x per cycle (each visit with a new colour/symmetry variant), and the same
    /// renderer never plays twice in a row unless nothing else is left.
    private var slots: [Mode] = []
    private func nextSlot(energy: Float) -> Mode {
        if slots.isEmpty {
            slots = [Mode](repeating: .visuals, count: 10) + [.aurora, .aurora, .aurora, .stage, .stage]
            slots.shuffle()
        }
        if let i = slots.lastIndex(where: { $0 != showScene }) { return slots.remove(at: i) }
        return slots.removeLast()
    }

    private func startTransition(to: Mode, type: Int, beats: Double, at beat: Double, ctx: SceneCtx) {
        switch to {
        case .visuals:
            if let v = visuals {
                v.autoCycle = false
                let loud = [0, 2, 6, 8, 9, 10, 11, 12, 13, 18, 20, 22, 24, 25, 27, 31], calm = [1, 3, 7, 14, 15, 16, 17, 19, 21, 23, 26, 28, 29, 30, 32]
                v.preset = v.nextFromBag(prefer: dropMoment || ctx.s.energy > 0.6 ? loud : calm)
                v.newVariant()
            }
        case .aurora: aurora?.newVariant(seed: srand(1000))
        case .stage: stage = Float(srand(4))
        default: break
        }
        transition = Transition(from: showScene, to: to, type: type, startBeat: beat, beats: beats)
        metrics.event("show:\(showScene.title)->\(to.title) [\(Self.transitionNames[type]) \(Int(beats))b]" + (to == .visuals ? " " + VisualsRenderer.presetNames[visuals?.preset ?? 0] + " pal\(visuals?.paletteIndex ?? 0)" : to == .aurora ? " sym\(aurora?.symmetry ?? 0)" : ""), at: ctx.now)
        showScene = to
        sceneStartBeat = beat
        lastTransitionType = type
    }
    private var lastTransitionType = -1
    private var dropMoment = false

    private func showStep(ctx: SceneCtx, beatClock: Double, locked: Bool, energy: Float) {
        // drops: flash-cut exactly on the drop kick to a big scene (fresh variant each time)
        if ctx.dropStarted {
            dropScenes += 1
            var target: Mode = [.stage, .aurora, .visuals][dropScenes % 3]
            if target == showScene { dropScenes += 1; target = [.stage, .aurora, .visuals][dropScenes % 3] }
            dropMoment = true
            startTransition(to: target, type: 0, beats: 1, at: beatClock, ctx: ctx)
            dropMoment = false
            return
        }
        guard transition == nil else { return }
        let bar = Int(floor(beatClock / 4))
        guard bar != lastBar else { return }
        lastBar = bar
        // loud music changes every 16 beats, calm every 32
        let hold: Double = intensity == .wild && energy > 0.6 ? 16 : (intensity == .chill ? 64 : 32)
        guard beatClock - sceneStartBeat >= hold - 0.01 else { return }
        let pick = nextSlot(energy: energy)
        // glitch (4) and pixel dissolve (5) are the harsh ones: Wild only
        let pool = intensity == .wild ? [1, 2, 3, 4, 5, 6] : [1, 2, 3, 6]
        var type = pool[srand(pool.count)]; if type == lastTransitionType { type = pool[(pool.firstIndex(of: type)! + 1) % pool.count] }
        let beats: Double = intensity == .wild && energy > 0.7 ? [1, 2, 2][srand(3)] : [4, 4, 8][srand(3)]
        startTransition(to: pick, type: type, beats: beats, at: Double(bar * 4), ctx: ctx)
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
