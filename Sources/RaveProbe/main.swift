import AVFoundation
import CoreMedia
import Foundation
import RaveAudio

func fmt(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }

func loadMono(_ path: String) throws -> ([Float], Double) {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = f.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    let n = Int(buf.frameLength), cc = Int(format.channelCount)
    var out = [Float](repeating: 0, count: n)
    for c in 0..<cc { let d = buf.floatChannelData![c]; for i in 0..<n { out[i] += d[i] / Float(cc) } }
    return (out, format.sampleRate)
}

func report(_ name: String, _ r: TempoRun, truth: Double?, from: Double = 0) {
    let lock = truth.flatMap { r.lockTime(truth: $0, from: from) }
    let err = truth.map { abs(r.finalBPM - $0) } ?? .nan
    print("\(name.padding(toLength: 22, withPad: " ", startingAt: 0)) truth=\(truth.map { fmt($0, 1) } ?? "?")  final=\(fmt(r.finalBPM))  err=\(fmt(err, 2))  lock=\(lock.map { fmt($0) + "s" } ?? "NO LOCK")  conf=\(fmt(r.timeline.last?.conf ?? 0))  kicks=\(r.kicks) snares=\(r.snares) hats=\(r.hats)")
}

nonisolated(unsafe) var atexit_pid: pid_t = 0
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"

switch mode {
case "synth":
    for p in [Synth.house, Synth.dnb, Synth.boomBap, Synth.rock, Synth.metal, Synth.techno] {
        report(p.name, TempoRun.run(Synth.render(p, seconds: 20), sr: 48000), truth: p.bpm)
    }
    var a = Synth.house; a.bpm = 124
    var b = Synth.house; b.bpm = 132
    let mix = Synth.render(a, seconds: 15) + Synth.render(b, seconds: 15, seed: 7)
    report("transition 124->132", TempoRun.run(mix, sr: 48000), truth: 132, from: 15)

case "trace":
    let name = args[2]
    let all = [Synth.house, Synth.dnb, Synth.boomBap, Synth.rock, Synth.metal, Synth.techno]
    let p = all.first { $0.name == name }!
    let r = TempoRun.run(Synth.render(p, seconds: 12), sr: 48000)
    for e in r.timeline where Int((e.t * 4).rounded() * 100) == Int(e.t * 400) || true {
        if abs(e.t * 4 - (e.t * 4).rounded()) < 0.006 { print("t=\(fmt(e.t,2)) bpm=\(fmt(e.bpm)) conf=\(fmt(e.conf))") }
    }

case "file":
    let path = args[2]
    let truth = args.count > 3 ? Double(args[3]) : nil
    let (s, sr) = try loadMono(path)
    let start = args.count > 4 ? Int((Double(args[4]) ?? 0) * sr) : 0
    let clip = Array(s[min(start, s.count)..<min(s.count, start + Int((Double(ProcessInfo.processInfo.environment["RAVE_CLIP"] ?? "30") ?? 30) * sr))])
    let ref = ProcessInfo.processInfo.environment["RAVE_REFEREE"] != nil ? BeatReferee(synchronous: true) : nil
    let r = TempoRun.run(clip, sr: sr, referee: ref)
    ref?.stop()
    if let st = r.refereeStatus { print("REFEREE reports=\(st.reports) tempoFixes=\(st.tempoFixes) phaseFixes=\(st.phaseFixes) barFixes=\(st.barFixes) rejected=\(st.rejected) refBPM=\(fmt(st.refBPM)) ms=\(st.lastMs) last=\(st.lastAction)") }
    report((path as NSString).lastPathComponent, r, truth: truth)
    if let tr = truth {
        let l1 = r.lockTime(truth: tr), l2 = r.lockTime(truth: tr * 2), l3 = r.lockTime(truth: tr / 2)
        print("BENCH final=\(fmt(r.finalBPM)) lock_exact=\(l1.map { fmt($0) } ?? "-") lock_x2=\(l2.map { fmt($0) } ?? "-") lock_half=\(l3.map { fmt($0) } ?? "-") conf=\(fmt(r.timeline.last?.conf ?? 0))")
    }
    if let outp = ProcessInfo.processInfo.environment["RAVE_BEATS_OUT"] {
        let d: [String: Any] = ["start": Double(start) / sr, "beats": r.beats, "beatInBar": r.beatInBar, "barConf": r.barConf, "flywheel": r.flywheelTimes.enumerated().filter { $0.offset % 10 == 0 }.map { $0.element },
                                "bpm": r.timeline.map { $0.bpm }.enumerated().filter { $0.offset % 47 == 0 }.map { $0.element }]
        try JSONSerialization.data(withJSONObject: d).write(to: URL(fileURLWithPath: outp))
    }
    if ProcessInfo.processInfo.environment["RAVE_TRACE"] != nil {
        for e in r.timeline where Int(e.t * 100) % 100 == 0 { print("  t=\(fmt(e.t,1))s bpm=\(fmt(e.bpm)) conf=\(fmt(e.conf))") }
    }

case "live":
    // rave-probe live [seconds] [--play file] [--mic]
    let secs = args.count > 2 ? Double(args[2]) ?? 20 : 20
    let playIdx = args.firstIndex(of: "--play")
    let useMic = args.contains("--mic")
    if !useMic && !CapturePermission.screenRecordingGranted {
        CapturePermission.requestScreenRecording()
        print("PERMISSION: Screen Recording not granted.\n" + CapturePermission.fixInstructions)
    }
    final class State: @unchecked Sendable {
        var analyzer: LiveAnalyzer?
        var t0 = Date()
        var firstSound: Double?
        var armed = false
        var firstOnset: Double?
        var lockAt: Double?
        var last: AnalysisFrame?
        var stable = 0
        var prevBPM = 0.0
        var cbLatencies: [Double] = []
        var referee: BeatReferee?
        var beatHost: [Double] = []      // host time of each predicted beat (same clock as playHost)
        var beatInBar: [Int] = []
        var bpmLog: [Double] = []
        var playHost = 0.0
        let lock = NSLock()
    }
    let st = State()
    let handler: SampleHandler = { buf, sr, pts in
        st.lock.lock(); defer { st.lock.unlock() }
        if st.analyzer == nil { st.analyzer = LiveAnalyzer(sampleRate: sr) }
        // capture->callback latency: host clock now minus buffer PTS end
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        st.cbLatencies.append(now - (pts + Double(buf.count) / sr))
        let frames = st.analyzer!.process(buf)
        if let ref = st.referee { ref.feed(buf, sampleRate: sr); ref.step(st.analyzer!) }   // same path as the app's AudioEngine.ingest
        let bufEnd = pts + Double(buf.count) / sr, streamEnd = frames.last?.time ?? 0
        for f in frames {
            if f.isBeat && st.armed { st.beatHost.append(bufEnd - (streamEnd - f.beatTime)); st.beatInBar.append(f.beatInBar); st.bpmLog.append(f.bpm) }
            let el = Date().timeIntervalSince(st.t0)
            if !f.silent && st.firstSound == nil && st.armed {
                st.firstSound = el
                print("FIRST_SOUND el=\(fmt(el,4)) rms=\(f.rms) streamT=\(fmt(f.time,3)) bufPTS=\(fmt(pts,4)) hostNow=\(fmt(now,4))")
            }
            if (f.kick || f.onset > 5) && st.firstSound != nil && st.firstOnset == nil { st.firstOnset = el }
            if f.bpm > 0 && abs(f.bpm - st.prevBPM) / f.bpm < 0.01 { st.stable += 1 } else { st.stable = 0 }
            st.prevBPM = f.bpm
            if st.lockAt == nil && st.stable > Int(2 * 93.75) && f.confidence > 0.3 { st.lockAt = el - 2 }
            st.last = f
        }
    }
    var player: Process?
    if ProcessInfo.processInfo.environment["RAVE_REFEREE"] != nil { st.referee = BeatReferee() }   // live: async, like the app
    let sys = SystemAudioCapture()
    let mic = MicCapture()
    if useMic {
        _ = await MicCapture.requestPermission()
        mic.onSamples = handler
        try mic.start()
    } else {
        sys.onSamples = handler
        sys.onError = { print("capture error: \($0)") }
        do { try await sys.start() } catch { print("START FAILED: \(error)\n" + CapturePermission.fixInstructions); exit(2) }
    }
    try await Task.sleep(nanoseconds: 1_000_000_000) // let the stream settle in silence
    acquire(st.lock); st.t0 = Date(); st.firstSound = nil; st.firstOnset = nil; st.lockAt = nil; st.armed = true; release(st.lock)
    print("ARMED hostNow=\(fmt(CMClockGetTime(CMClockGetHostTimeClock()).seconds,4))")
    if let pi = playIdx, args.count > pi + 1 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [args[pi + 1]]
        acquire(st.lock); st.playHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds; release(st.lock)
        try p.run(); player = p
        // Never leave a song playing: kill the player on Ctrl-C/kill and on normal exit.
        let pid = p.processIdentifier
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { kill(pid, SIGTERM); exit(130) }
            src.resume(); signalSources.append(src)
        }
        atexit_pid = pid
        atexit { if atexit_pid > 0 { kill(atexit_pid, SIGTERM) } }
        print("PLAY pressed at t=0 (afplay \((args[pi + 1] as NSString).lastPathComponent))")
    }
    if let oi = args.firstIndex(of: "--open"), args.count > oi + 1 {
        // "Press play" in a browser: open the URL (e.g. YouTube) at t=0.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Safari", args[oi + 1]]
        try p.run()
        print("OPEN at t=0 \(args[oi + 1])")
    }
    let ticks = Int(secs * 2)
    for _ in 0..<ticks {
        try await Task.sleep(nanoseconds: 500_000_000)
        acquire(st.lock)
        if let f = st.last {
            let el = Date().timeIntervalSince(st.t0)
            print("t=\(fmt(el,1))s rms=\(fmt(Double(f.rms),4)) energy=\(fmt(Double(f.energy))) bands=\(f.bands.map { fmt(Double($0)) }.joined(separator: ",")) bpm=\(fmt(f.bpm)) conf=\(fmt(f.confidence)) silent=\(f.silent)")
        } else { print("no audio buffers yet") }
        release(st.lock)
    }
    player?.terminate(); player?.waitUntilExit()
    acquire(st.lock)
    let lat = st.cbLatencies.dropFirst(10).sorted()
    func pct(_ q: Double) -> Double { lat.isEmpty ? .nan : lat[min(lat.count - 1, Int(Double(lat.count) * q))] * 1000 }
    print("RESULT first_sound=\(st.firstSound.map { fmt($0, 3) + "s" } ?? "none") first_onset=\(st.firstOnset.map { fmt($0, 3) + "s" } ?? "none") lock=\(st.lockAt.map { fmt($0) + "s" } ?? "none") final_bpm=\(fmt(st.last?.bpm ?? 0)) conf=\(fmt(st.last?.confidence ?? 0))")
    if let outp = ProcessInfo.processInfo.environment["RAVE_BEATS_OUT"] {
        // beats relative to the moment afplay was launched (file time + a constant: afplay start + output + capture latency)
        let d: [String: Any] = ["beats": st.beatHost.map { $0 - st.playHost }, "beatInBar": st.beatInBar, "bpm": st.bpmLog,
                                "referee": st.referee.map { ["reports": $0.status.reports, "tempoFixes": $0.status.tempoFixes, "phaseFixes": $0.status.phaseFixes, "barFixes": $0.status.barFixes, "rejected": $0.status.rejected] } ?? [:]]
        if let data = try? JSONSerialization.data(withJSONObject: d) { try? data.write(to: URL(fileURLWithPath: outp)) }
    }
    st.referee?.stop()
    print("RESULT capture_to_callback_ms p50=\(fmt(pct(0.5),1)) p95=\(fmt(pct(0.95),1)) max=\(fmt(lat.last.map { $0 * 1000 } ?? .nan,1)) buffers=\(useMic ? 0 : sys.buffersReceived) pts_gaps=\(useMic ? 0 : sys.droppedGaps)")
    release(st.lock)
    if !useMic { await sys.stop() } else { mic.stop() }

default:
    print("usage: rave-probe synth | file <path> [truthBPM] [startSec] | live [seconds] [--play file] [--mic]")
}

// Synchronous wrappers: calling NSLock.lock() directly from async code warns (error in Swift 6 mode).
func acquire(_ l: NSLock) { l.lock() }
func release(_ l: NSLock) { l.unlock() }
