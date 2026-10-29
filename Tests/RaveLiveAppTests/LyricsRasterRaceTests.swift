import XCTest
import AppKit
@testable import RaveLiveApp

/// A line whose raster is still being drawn in the background must still appear when it becomes current.
/// (Found by Astra's QA: prepare() pre-rasters the next line, so this hits normal playback.)
final class LyricsRasterRaceTests: XCTestCase {
    private func pump(_ seconds: Double = 1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private func play(_ v: LyricsStageView, t: Double) {
        let now = CACurrentMediaTime()
        for i in 0..<60 { v.frame(t: t, drive: LyricDrive(), now: now + Double(i) / 60) }
    }

    /// The next line was prefetched and its raster is still pending when it becomes the current line.
    func testPrefetchedLineStillPendingWhenItBecomesCurrentIsShown() {
        let v = LyricsStageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let text = "next line ready now"
        v.prepare(text)
        v.setLine(index: 1, text: text, words: WordTiming.estimate(text: text, start: 2, nextStart: 4), next: "")
        pump()
        play(v, t: 2.5)
        XCTAssertGreaterThan(v.lastUnitCount, 0, "the waiting current line must get the prefetched raster")
        XCTAssertEqual(v.visibleLineCount, 1, v.debugGeometry)
        XCTAssertEqual(v.rasterCount, 1, "one raster job serves both the prefetch and the line")
    }

    /// Fast track change to a song whose first line has the same text, before the first raster is back.
    func testSameTextAfterClearWhileRasterPendingIsShown() {
        let v = LyricsStageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let text = "identical chorus"
        let w = WordTiming.estimate(text: text, start: 0, nextStart: 4)
        v.setLine(index: 0, text: text, words: w, next: "")
        v.clear()
        v.setLine(index: 0, text: text, words: w, next: "")
        pump()
        play(v, t: 1)
        XCTAssertEqual(v.visibleLineCount, 1, v.debugGeometry)
        XCTAssertGreaterThan(v.lastUnitCount, 0)
    }

    /// A restyle while a raster is in flight: the old job must not feed the new style's line, and the line still shows.
    func testRestyleWhileRasterPendingShowsTheNewStyle() {
        let v = LyricsStageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let text = "style flip mid flight"
        v.setLine(index: 0, text: text, words: WordTiming.estimate(text: text, start: 0, nextStart: 4), next: "")
        v.style = .neon
        v.style = .clean
        pump()
        play(v, t: 1)
        XCTAssertEqual(v.visibleLineCount, 1, v.debugGeometry)
        XCTAssertGreaterThan(v.lastUnitCount, 0)
    }

    /// Every style (except chunked Pop, which rasterises per chunk) shows a prefetched-then-current line.
    func testPrefetchRaceAcrossStyles() {
        for st in LyricStyle.allCases where st != .auto {
            let v = LyricsStageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
            v.style = st
            let text = "every style shows this"
            v.prepare(text)
            v.setLine(index: 1, text: text, words: WordTiming.estimate(text: text, start: 2, nextStart: 4), next: "")
            pump(0.6)
            play(v, t: 2.5)
            XCTAssertEqual(v.visibleLineCount, 1, "\(st): \(v.debugGeometry)")
        }
    }
}
