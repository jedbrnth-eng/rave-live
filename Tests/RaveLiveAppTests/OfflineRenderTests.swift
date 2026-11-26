// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Metal
import XCTest
@testable import RaveLiveApp

/// `--offscreen`: a fixed render clock, a pumped demo feed and seeded shuffle bags make a render repeatable.
final class OfflineRenderTests: XCTestCase {
    override func tearDown() {
        RenderClock.fixed = nil
        super.tearDown()
    }

    func testSeededGeneratorRepeatsPerSeed() {
        var a = SeededGenerator(seed: 7), b = SeededGenerator(seed: 7), c = SeededGenerator(seed: 8)
        var xa: [UInt64] = [], xb: [UInt64] = [], xc: [UInt64] = []
        for _ in 0..<8 { xa.append(a.next()); xb.append(b.next()); xc.append(c.next()) }
        XCTAssertEqual(xa, xb)
        XCTAssertNotEqual(xa, xc)
        var s = SeededGenerator(seed: 3), t = SeededGenerator(seed: 3)
        XCTAssertEqual(Array(0..<48).shuffled(using: &s), Array(0..<48).shuffled(using: &t))
        var z = SeededGenerator(seed: 0)                     // a zero seed must not lock xorshift at zero
        XCTAssertNotEqual(z.next(), 0)
    }

    func testFixedClockDrivesHostTimeAndMetricEventTimes() throws {
        RenderClock.fixed = 1000
        XCTAssertEqual(hostNow(), 1000)
        let m = Metrics()                                    // starts at host 1000
        RenderClock.fixed = 1012.5
        m.event("drop(build)", at: 1010)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offline-metrics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        m.dump(to: url, wait: true)
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let ev = try XCTUnwrap((d["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(ev["event"] as? String, "drop(build)")
        XCTAssertEqual(try XCTUnwrap(ev["t"] as? Double), 10, accuracy: 1e-9)     // on the render clock, not the wall clock
        XCTAssertEqual(try XCTUnwrap(d["elapsed_s"] as? Double), 12.5, accuracy: 1e-9)
    }

    /// The demo pumped frame by frame hears the same kicks and locks to the same tempo and phase every time.
    func testPumpedDemoIsRepeatable() {
        func run() -> AudioSnapshot {
            let a = AudioEngine()
            a.refereeEnabled = false
            a.prepareDemo(at: 500)
            for i in 1...(10 * 60) { a.pumpDemo(until: 500 + Double(i) / 60) }
            return a.snapshot()
        }
        let x = run(), y = run()
        XCTAssertGreaterThan(x.kickCount, 10)
        XCTAssertEqual(x.kickCount, y.kickCount)
        XCTAssertEqual(x.snareCount, y.snareCount)
        XCTAssertEqual(x.bpm, y.bpm)
        XCTAssertEqual(x.beatPhase, y.beatPhase)
        XCTAssertEqual(x.bpm, 128, accuracy: 1.5)
    }

    /// Two offscreen renders with one seed give byte-identical frames, and the frames aren't black.
    func testOffscreenRenderIsRepeatableAndNotBlack() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this machine") }
        let savedTier = QualityTier.active, savedSeed = RenderClock.seed
        defer { QualityTier.active = savedTier; RenderClock.seed = savedSeed }
        func render() throws -> [[UInt8]] {
            RenderClock.seed = 11
            let start = 2000.0
            RenderClock.fixed = start
            let rig = try XCTUnwrap(OfflineRender.makeRig(device: dev, width: 160, height: 90, quality: "low"))
            rig.renderer.applyLaunchFlags(["--stage"])
            rig.audio.prepareDemo(at: start)
            var frames: [[UInt8]] = []
            for i in 1...60 {
                OfflineRender.step(rig, index: i, start: start, fps: 60, demo: true)
                if i % 20 == 0, let tex = rig.renderer.offscreenFrame {
                    var px = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
                    tex.getBytes(&px, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
                    frames.append(px)
                }
            }
            return frames
        }
        let a = try render(), b = try render()
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a, b, "same seed, same clock: frames must match byte for byte")
        let last = try XCTUnwrap(a.last)
        var sum = 0.0
        for i in stride(from: 0, to: last.count, by: 4) { sum += 0.114 * Double(last[i]) + 0.587 * Double(last[i + 1]) + 0.299 * Double(last[i + 2]) }
        XCTAssertGreaterThan(sum / Double(last.count / 4), 3, "the Stage frame is black")
    }
}
