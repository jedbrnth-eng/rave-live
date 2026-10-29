// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
@testable import RaveLiveApp

/// Fixes from the 2026-10-29 perf / robustness audit (P2-1, P2-2, P2-3, P2-4, P3-2, P3-7, P3-8).
final class RobustnessTests: XCTestCase {
    private func wait(_ s: Double) { let e = expectation(description: "wait"); DispatchQueue.global().asyncAfter(deadline: .now() + s) { e.fulfill() }; wait(for: [e], timeout: s + 5) }
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Fake adapter in its own folder (the folder name tags every process it starts, for pgrep).
    private func fakeAdapter(_ body: String) throws -> (NowPlayingSource.Adapter, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-np-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake.pl")
        try body.write(to: script, atomically: true, encoding: .utf8)
        return (.init(script: script, framework: dir), dir)
    }
    private func pgrep(_ pattern: String) -> [pid_t] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", pattern]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }
    private func cleanup(_ dir: URL) {
        for pid in pgrep(dir.lastPathComponent) { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: P2-1 Now Playing adapter lifecycle

    /// The real adapter can miss a SIGTERM that lands in its first milliseconds (quick Y/N toggles left orphans).
    /// stop() must SIGKILL a child that is still alive after the grace period.
    func testStopKillsAnAdapterThatIgnoresSIGTERM() throws {
        let (a, dir) = try fakeAdapter("$SIG{TERM} = 'IGNORE'; sleep 30;\n")
        defer { cleanup(dir) }
        let src = NowPlayingSource(adapter: a)
        src.start()
        wait(0.6)
        let pid = try XCTUnwrap(src.debugPID)
        src.stop()
        wait(1.2)                                  // 0.3 s grace + the watcher's 0.5 s poll
        XCTAssertFalse(alive(pid), "adapter that ignores SIGTERM survived stop()")
        XCTAssertEqual(pgrep(dir.lastPathComponent), [], "adapter or watcher process left behind")
    }

    /// Quick toggles: start/stop every 20 ms. Nothing may be left running afterwards.
    func testRapidTogglesLeaveNoProcesses() throws {
        let (a, dir) = try fakeAdapter("$SIG{TERM} = 'IGNORE'; sleep 30;\n")
        defer { cleanup(dir) }
        let src = NowPlayingSource(adapter: a)
        for _ in 0..<25 { src.start(); usleep(20_000); src.stop(); usleep(20_000) }
        wait(1.5)
        XCTAssertEqual(pgrep(dir.lastPathComponent), [], "rapid toggles left adapter processes running")
    }

    /// quit path: stop(waitForExit:) returns with the child gone.
    func testStopWaitingForExitReturnsWithTheChildGone() throws {
        let (a, dir) = try fakeAdapter("$SIG{TERM} = 'IGNORE'; sleep 30;\n")
        defer { cleanup(dir) }
        let src = NowPlayingSource(adapter: a)
        src.start()
        wait(0.6)
        let pid = try XCTUnwrap(src.debugPID)
        src.stop(waitForExit: true)
        usleep(50_000)                             // let Foundation reap it
        XCTAssertFalse(alive(pid))
    }

    /// The app crashes or is force-quit: the adapter must not outlive it. A helper process stands in for RAVE LIVE,
    /// starts the adapter exactly as the app does, and is SIGKILLed. A control adapter started without the watchdog
    /// survives the same thing, which shows the test can see the bug.
    func testAdapterDiesWhenTheAppIsKilled() throws {
        let (a, dir) = try fakeAdapter("$SIG{TERM} = 'IGNORE'; sleep 30;\n")
        defer { cleanup(dir) }
        func spawnFakeApp(_ adapterArgs: [String]) throws -> (Process, pid_t) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", "$| = 1; my $c = fork(); if ($c == 0) { exec('/usr/bin/perl', @ARGV) or exit 127 } print \"$c\\n\"; sleep 60;", "--"] + adapterArgs
            let out = Pipe(); p.standardOutput = out
            try p.run()
            var line = Data()
            while !line.contains(0x0A) { let d = out.fileHandleForReading.availableData; if d.isEmpty { break }; line.append(d) }
            let pid = try XCTUnwrap(pid_t(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            return (p, pid)
        }
        let (app, adapter) = try spawnFakeApp(NowPlayingSource.launchArguments(a))
        let (ctlApp, control) = try spawnFakeApp([a.script.path, a.framework.path, "stream"])   // the old launch, no watchdog
        defer { kill(control, SIGKILL) }
        wait(0.8)
        XCTAssertTrue(alive(adapter)); XCTAssertTrue(alive(control))
        kill(app.processIdentifier, SIGKILL); kill(ctlApp.processIdentifier, SIGKILL)  // "crash"
        app.waitUntilExit(); ctlApp.waitUntilExit()
        var gone = false
        for _ in 0..<30 where !gone { wait(0.1); gone = !alive(adapter) }
        XCTAssertTrue(gone, "adapter outlived the killed app")
        XCTAssertTrue(alive(control), "control adapter (old launch) should survive: otherwise this test proves nothing")
    }

    // MARK: P2-2 malformed 200 answers

    final class FakeNet: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answer: (URLRequest) throws -> (Data, Int)
        init(_ a: @escaping (URLRequest) throws -> (Data, Int)) { answer = a }
        func transport() -> LRCLIBClient.Transport { { [self] req in requests.append(req); return try answer(req) } }
    }

    /// A captive portal answers every URL with 200 and an HTML login page. That must not become a cached "not found".
    func testCaptivePortalHTMLIsNotCached() async {
        let html = Data("<html><body>Hotel Wi-Fi: please log in</body></html>".utf8)
        let net = FakeNet { _ in (html, 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookupDetailed(title: "Probe Song", artist: "Probe Artist", album: nil, duration: 200)
        XCTAssertEqual(r.result, .offline)
        XCTAssertFalse(r.cacheable)
        XCTAssertFalse(LyricsCache.shouldStore(r.result, cacheable: r.cacheable, gate: nil))
    }

    /// Truncated JSON on search with a 404 on get (the auditor's mock): not cacheable either.
    func testTruncatedSearchBodyIsNotCached() async {
        let net = FakeNet { req in req.url?.path == "/api/get" ? (Data("{}".utf8), 404) : (Data(#"[{"id":1,"trackName":"Pro"#.utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookupDetailed(title: "Probe Song", artist: "Probe Artist", album: nil, duration: 200)
        XCTAssertFalse(r.cacheable)
        XCTAssertNotEqual(r.result, .notFound)
    }

    /// A real empty search (`[]`) after a real 404 is still a cacheable "not found".
    func testRealEmptySearchIsStillCached() async {
        let net = FakeNet { req in req.url?.path == "/api/get" ? (Data("{}".utf8), 404) : (Data("[]".utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookupDetailed(title: "Probe Song", artist: "Probe Artist", album: nil, duration: 200)
        XCTAssertEqual(r.result, .notFound)
        XCTAssertTrue(r.cacheable)
    }

    /// HTML on /api/get, valid `[]` on search: the exact lookup never happened, so don't store the miss.
    func testHTMLOnGetMakesTheMissUncacheable() async {
        let net = FakeNet { req in req.url?.path == "/api/get" ? (Data("<html/>".utf8), 200) : (Data("[]".utf8), 200) }
        let c = LRCLIBClient(host: "https://lrc.example", transport: net.transport(), retryDelay: 0)
        let r = await c.lookupDetailed(title: "Probe Song", artist: "Probe Artist", album: nil, duration: 200)
        XCTAssertFalse(r.cacheable)
    }

    // MARK: P3-2 retry backoff, P3-8 titles in logs

    func testOfflineRetriesBackOff() {
        let d = (0..<8).map { LyricsController.retryDelay(attempt: $0) }
        XCTAssertEqual(Array(d.prefix(5)), [30, 60, 120, 240, 480])
        XCTAssertEqual(d.last, 600)
        XCTAssertEqual(LyricsController.retryDelay(attempt: 1000), 600)
    }

    func testTitleTagHidesTheTitle() {
        let t = LyricsController.titleTag("Some Private Song Name", "Some Artist")
        XCTAssertTrue(t.hasPrefix("track#"))
        XCTAssertFalse(t.contains("Private"))
        XCTAssertEqual(t, LyricsController.titleTag("Some Private Song Name", "Some Artist"))
        XCTAssertNotEqual(t, LyricsController.titleTag("Some Private Song Name", "Other Artist"))
        XCTAssertEqual(LyricsController.titleTag(String(repeating: "x", count: 20_000), "a").count, 14)
    }

    // MARK: P2-4 lyrics breath without text rebuilds

    func testCostRing() {
        var r = CostRing()
        XCTAssertEqual(r.percentile(0.95), 0)
        for i in 1...100 { r.add(Double(i)) }
        XCTAssertEqual(r.count, 100)
        XCTAssertEqual(r.percentile(0.95), 95, accuracy: 1)
        XCTAssertEqual(r.max, 100)
        for _ in 0..<10_000 { r.add(1) }
        XCTAssertEqual(r.count, 4096, "bounded")
    }

    /// Every style: 10 s of frames with the music moving never rasterises text again (only layer properties change).
    func testFramesDoNotRebuildTheText() {
        for style in LyricStyle.allCases where style != .auto {
            let v = LyricsStageView(frame: NSRect(x: 0, y: 0, width: 960, height: 400))
            v.style = style
            let ws = WordTiming.estimate(text: "a made up lyric line here", start: 0, nextStart: 3)
            v.setLine(index: 0, text: "a made up lyric line here", words: ws, next: "the next made up line")
            v.frame(t: 0.1, drive: LyricDrive(), now: 99)          // Pop rasterises its first chunk on the first frame
            let deadline = Date().addingTimeInterval(3)
            while v.rasterCount < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            let after = v.rasterCount
            XCTAssertGreaterThan(after, 0, "\(style)")
            var d = LyricDrive(); d.locked = true; d.bpm = 128
            for i in 0..<600 {                                     // 10 s at 60 fps
                d.beatPhase = Double(i % 28) / 28; d.kick = i % 28 < 3 ? 1 : 0; d.energy = Float(i % 100) / 100
                d.bands = [0.8, 0.6, 0.4, 0.3, 0.2]
                v.frame(t: Double(i) / 60 * 0.5, drive: d, now: 100 + Double(i) / 60)
            }
            if style != .pop { XCTAssertEqual(v.rasterCount, after, "\(style) rasterised during frames") }
            XCTAssertLessThanOrEqual(v.visibleLineCount, 1)
        }
    }

    // MARK: P3-7 audio source pick in test runs

    private func freshDefaults() -> UserDefaults {
        let name = "ravelive.audio.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testAudioSourcePickIsNotSavedInTestRuns() {
        let d = freshDefaults()
        d.set("system", forKey: "audioSource")
        let frozen = Prefs(defaults: d, frozen: true)
        InputSource.save(.device("uid-123"), in: frozen)                // the M key in a --autoquit run
        XCTAssertEqual(d.string(forKey: "audioSource"), "system", "test run overwrote the saved audio source")
        XCTAssertNil(d.string(forKey: "lastInputDevice"))
        let live = Prefs(defaults: d, frozen: false)
        InputSource.save(.device("uid-123"), in: live)
        XCTAssertEqual(d.string(forKey: "audioSource"), "device:uid-123")
        XCTAssertEqual(d.string(forKey: "lastInputDevice"), "uid-123")
        XCTAssertEqual(InputSource.saved(in: live), .device("uid-123"))
        XCTAssertNotEqual(InputSource.saved(in: frozen), .device("uid-123"), "test runs read the default, not the saved pick")
    }

    // MARK: P2-3 capture recovery

    private final class Counter: @unchecked Sendable { var n = 0; var failFirst = 0 }

    /// A simulated ScreenCaptureKit stop triggers exactly one restart; several interruptions in a row (wake sends more
    /// than one notification) fold into it.
    func testStopTriggersOneRestart() {
        let c = Counter()
        let r = CaptureRestarter { c.n += 1 }
        var lines: [String] = []
        r.log = { lines.append($0) }
        r.interrupted("stream stopped", settle: 0.1)
        r.interrupted("woke from sleep", settle: 0.1)
        r.interrupted("screens woke", settle: 0.1)
        let e = expectation(description: "restart"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { e.fulfill() }
        wait(for: [e], timeout: 3)
        XCTAssertEqual(c.n, 1)
        XCTAssertFalse(r.pending)
        XCTAssertTrue(lines.contains { $0.hasPrefix("capture: restarted") }, "\(lines)")
    }

    /// A failing restart retries with backoff and clears the status once it works.
    func testFailedRestartRetriesWithBackoff() {
        struct Boom: Error {}
        let c = Counter(); c.failFirst = 2
        let r = CaptureRestarter { c.n += 1; if c.n <= c.failFirst { throw Boom() } }
        var statuses: [String?] = []
        r.onStatus = { statuses.append($0) }
        r.interrupted("stream stopped", settle: 0.05)
        XCTAssertEqual(CaptureRestarter.delay(failures: 1, settle: 0), 1)
        XCTAssertEqual(CaptureRestarter.delay(failures: 2, settle: 0), 2)
        XCTAssertEqual(CaptureRestarter.delay(failures: 9, settle: 0), 30)
        let e = expectation(description: "recovered"); DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { e.fulfill() }   // 0.05 + 1 + 2 s, plus slack
        wait(for: [e], timeout: 8)
        XCTAssertEqual(c.n, 3)
        XCTAssertEqual(r.failures, 0)
        XCTAssertEqual(statuses.count, 3)
        XCTAssertNil(statuses.last ?? "x", "status not cleared after recovery")
    }

    /// The user picks another source while a restart is pending: nothing restarts.
    func testCancelDropsAPendingRestart() {
        let c = Counter()
        let r = CaptureRestarter { c.n += 1 }
        r.interrupted("stream stopped", settle: 0.2)
        r.cancel()
        let e = expectation(description: "wait"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { e.fulfill() }
        wait(for: [e], timeout: 3)
        XCTAssertEqual(c.n, 0)
    }
}
