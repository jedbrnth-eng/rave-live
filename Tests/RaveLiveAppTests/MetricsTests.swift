// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
import QuartzCore
@testable import RaveLiveApp

/// P1 (perf audit 2026-10-29): the 2 s metrics dump sorted every frame time of the set on the main (render) thread,
/// so the stall grew with set length (135-245 ms per dump after ~28 min at 120 fps).
final class MetricsTests: XCTestCase {
    private func tmpURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rl-metrics-\(UUID().uuidString).json") }

    /// A 30-minute set at 120 fps with the app's 2 s dump cadence. The time each dump costs the render thread must stay
    /// flat (the old code went from ~4 ms to >100 ms) and small.
    func testDumpCostStaysFlatOverALongSet() throws {
        let m = Metrics()
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fps = 120, minutes = 30, dumpEvery = 2 * fps
        let total = fps * 60 * minutes
        var costs: [Double] = []
        var frameWork: [Double] = []                     // per-frame bookkeeping cost, sampled
        for i in 0..<total {
            let t = CACurrentMediaTime()
            m.frame(interval: 1.0 / 120 + Double(i % 7) * 1e-4)
            m.gpu(0.004 + Double(i % 5) * 1e-4)
            m.present(0.03)
            if i % 40 == 0 { m.flash(at: Double(i) / 120) }
            if i % 600 == 0 { m.event("show:AURORA->Classic Visuals [iris 4b] Mandala pal6", at: CACurrentMediaTime()) }
            if i % 997 == 0 { frameWork.append(CACurrentMediaTime() - t) }
            if i % dumpEvery == dumpEvery - 1 { costs.append(m.dump(to: url)) }
        }
        m.flush()
        XCTAssertEqual(costs.count, total / dumpEvery)
        let k = costs.count / 10
        func mean(_ a: ArraySlice<Double>) -> Double { a.reduce(0, +) / Double(a.count) }
        let early = mean(costs.prefix(k)), late = mean(costs.suffix(k))
        let sorted = costs.sorted(), p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print(String(format: "metrics dump on the calling thread: first 3 min mean %.3f ms, last 3 min mean %.3f ms, p95 %.3f ms, max %.3f ms (%d dumps, %d frames)",
                     early * 1000, late * 1000, p95 * 1000, sorted.last! * 1000, costs.count, total))
        XCTAssertLessThan(p95, 0.002, "dump() must cost < 2 ms on the render thread")
        XCTAssertLessThan(late, early + 0.001, "dump() cost grew with set length")
        let fw = frameWork.sorted()[frameWork.count / 2]
        XCTAssertLessThan(fw, 0.0002, "per-frame metrics bookkeeping should be microseconds")

        // the file is complete, valid JSON with the whole-run numbers
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(d["frames"] as? Int, total)
        let fi = try XCTUnwrap(d["frame_interval_ms"] as? [String: Any])
        let p50 = try XCTUnwrap(fi["p50"] as? Double)
        XCTAssertEqual(p50, 1000.0 / 120 + 0.3, accuracy: 0.05)
        XCTAssertLessThanOrEqual((d["events"] as? [Any])?.count ?? 0, Metrics.eventCap)
    }

    /// Whole-run percentiles from the histogram agree with an exact sort to within 0.2 %.
    func testHistogramPercentilesMatchExactSort() {
        var h = LogHistogram()
        var vals: [Double] = []
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50_000 {
            let v = Double.random(in: 0.006...0.012, using: &rng) + (Int.random(in: 0..<100, using: &rng) == 0 ? 0.05 : 0)
            vals.append(v); h.add(v)
        }
        let s = vals.sorted()
        for q in [0.5, 0.95, 0.99] {
            let exact = s[min(s.count - 1, Int(Double(s.count) * q))]
            XCTAssertEqual(h.percentile(q), exact, accuracy: exact * 0.002, "q=\(q)")
        }
        XCTAssertTrue(LogHistogram().percentile(0.5).isNaN)
        var z = LogHistogram(); z.add(.nan); z.add(-1); z.add(1e9)            // garbage never traps
        XCTAssertEqual(z.n, 3)
    }

    /// The event list is capped but keeps its head (the `renderer:t0` marker tests align smoothlogs with) and the newest
    /// entries; overlong names (20 000-char track titles) are cut.
    func testEventsAreCappedAndKeepTheirHead() throws {
        let m = Metrics()
        m.event("renderer:t0 host=1.0", at: CACurrentMediaTime())
        for i in 0..<5000 { m.event("e\(i)", at: CACurrentMediaTime()) }
        m.event(String(repeating: "x", count: 20_000), at: CACurrentMediaTime())
        XCTAssertEqual(m.eventCount, Metrics.eventCap)
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        m.dump(to: url, wait: true)
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let ev = try XCTUnwrap(d["events"] as? [[String: Any]]).compactMap { $0["event"] as? String }
        XCTAssertEqual(ev.first, "renderer:t0 host=1.0")
        XCTAssertEqual(ev[ev.count - 2], "e4999")
        XCTAssertLessThanOrEqual(ev.last!.count, Metrics.maxEventLength + 1)
        XCTAssertEqual(d["events_dropped"] as? Int, 5002 - Metrics.eventCap)
    }

    func testMaxFlashesPerSecondIsTrackedIncrementally() {
        let m = Metrics()
        for i in 0..<30 { m.flash(at: Double(i) * 0.34) }               // ~3 per second
        XCTAssertEqual(m.summary().maxFlashesPerSec, 3)
        for i in 0..<5 { m.flash(at: 20 + Double(i) * 0.1) }           // a burst of 5 inside 1 s
        XCTAssertEqual(m.summary().maxFlashesPerSec, 5)
    }

    /// The HUD's "latency p50" read "nan ms" before any kick was measured.
    func testHUDNumbersNeverPrintNaN() {
        XCTAssertEqual(Renderer.hudNumber(.nan, "%.0f"), "–")
        XCTAssertEqual(Renderer.hudNumber(.infinity, "%.1f"), "–")
        XCTAssertEqual(Renderer.hudNumber(36.4, "%.0f"), "36")
        XCTAssertTrue(Metrics().summary(recent: 600).latP50.isNaN)      // nothing measured yet: the case the HUD hit
    }

    /// Shader Lab entries vanish when their file is deleted; a stale preset index must not crash the HUD / SHOW log.
    func testStalePresetIndexHasAName() {
        XCTAssertEqual(VisualsRenderer.presetName(10_000), VisualsRenderer.presetNames[0])
        XCTAssertEqual(VisualsRenderer.presetName(-1), VisualsRenderer.presetNames[0])
        XCTAssertEqual(VisualsRenderer.presetName(2), VisualsRenderer.builtinNames[2])
    }
}
