import XCTest
import AppKit
@testable import RaveLiveApp

/// Edge cases from the 0.6.0 QA (Astra) and the PR #20 second-opinion review (DeepSeek).
final class LyricsHardeningTests: XCTestCase {
    private func make(_ words: [String], _ style: LyricStyle, size: CGFloat = 40, maxWidth: CGFloat = 600) -> LineRaster {
        LineRaster.make(.init(words: words, style: style, fontSize: size, maxWidth: maxWidth, scale: 1, key: "t",
                              font: LineRaster.font(style, size: size)))
    }

    /// A NaN or infinite hue must not trap in Int(h * 6) (no caller passes one today: a guard for later callers).
    func testHSVSurvivesNonFiniteHue() {
        for h in [CGFloat.nan, .infinity, -.infinity] {
            let (r, g, b) = LineRaster.hsv(h, 0.85, 1)
            XCTAssertTrue(r.isFinite && g.isFinite && b.isFinite, "\(h)")
        }
        let (r, g, b) = LineRaster.hsv(0, 1, 1)
        XCTAssertEqual([r, g, b], [1, 0, 0])
    }

    /// Bass wave splits words into letters; right-to-left words keep one shaped unit (joined Arabic letters, real width).
    func testRightToLeftWordInBassWaveKeepsItsShapeAndWidth() {
        let r = make(["مرحبا"], .wave)
        XCTAssertEqual(r.units.count, 1, "an RTL word is not split into isolated letters")
        XCTAssertEqual(r.units[0].rect.width, r.wordRects[0].width, accuracy: 0.5)
        let mixed = make(["hello", "שלום"], .wave)
        XCTAssertEqual(mixed.units.filter { $0.word == 0 }.count, 5, "left-to-right words still ride the wave per letter")
        XCTAssertEqual(mixed.units.filter { $0.word == 1 }.count, 1)
    }

    /// One word far wider than the lyric area: shrink (to half size at most), then cut it with an ellipsis so it fits.
    func testOverlongWordFitsTheLyricArea() {
        let r = make([String(repeating: "W", count: 300)], .clean)
        XCTAssertLessThanOrEqual(r.size.width, 601)
        XCTAssertGreaterThanOrEqual(r.fontSize, 20, "never smaller than half size")
        XCTAssertTrue(r.units[0].text.hasSuffix("…"))
        for st in [LyricStyle.neon, .wave, .spectrum, .pop] {
            XCTAssertLessThanOrEqual(make([String(repeating: "W", count: 300), "tail"], st).size.width, 601, "\(st)")
        }
        // A normal long word that fits at a smaller size is shrunk, not cut.
        let ok = make(["Supercalifragilisticexpialidocious"], .clean, size: 60)
        XCTAssertEqual(ok.units[0].text, "Supercalifragilisticexpialidocious")
        XCTAssertLessThanOrEqual(ok.size.width, 601)
    }

    /// `<00:10>hello<00:05>`: the trailing tag goes backwards, so the word tags are ignored (estimated timing is used).
    func testBackwardTrailingWordTagFallsBackToEstimatedTiming() {
        XCTAssertNil(LRC.parse("[00:10]<00:10>hello<00:05>")[0].words)
        XCTAssertNotNil(LRC.parse("[00:10]<00:10>hello<00:11>")[0].words, "a forward trailing tag still times the word")
    }

    /// A hostile or broken record (megabytes, tens of thousands of lines) is cut before parsing on the main thread.
    func testHugeLyricsRecordIsBounded() {
        let huge = String(repeating: "[00:01]<00:01>a <00:02>b <00:03>\n", count: 20000)
        let t = CACurrentMediaTime()
        let parsed = LRC.parse(huge)
        let dt = CACurrentMediaTime() - t
        XCTAssertLessThanOrEqual(parsed.count, LRC.maxLines)
        XCTAssertLessThanOrEqual(LRC.maxBytes, 128 * 1024)
        print("LRC bounded parse: \(parsed.count) lines in \(String(format: "%.3f", dt)) s")
        // A real song is untouched: 120 lines with word tags.
        var song = ""
        for i in 0..<120 { song += String(format: "[%02d:%02d.00]<%02d:%02d.00>la <%02d:%02d.50>la\n", i / 60, i % 60, i / 60, i % 60, i / 60, i % 60) }
        XCTAssertEqual(LRC.parse(song).count, 120)
    }
}
