// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
import AppKit
@testable import RaveLiveApp

/// Jed (10-29 20:08, screenshot): "weird black circle around the lyrics", and the old and new line overlapped.
final class LyricsLookTests: XCTestCase {
    func testNoShapeBehindTheText() {
        let v = LyricsOverlayView(frame: NSRect(x: 0, y: 0, width: 1600, height: 300))
        XCTAssertTrue(v.subviews.allSatisfy { $0 is NSTextField }, "only text, no scrim view: \(v.subviews)")
    }

    func testEveryGlyphHasADarkOutlineAndShadow() {
        let a = LyricsOverlayView.attributed("Line", size: 50, weight: .bold, alpha: 1)
        let attrs = a.attributes(at: 0, effectiveRange: nil)
        XCTAssertLessThan(attrs[.strokeWidth] as? Double ?? 0, 0, "negative stroke = fill + outline")
        let sh = attrs[.shadow] as? NSShadow
        XCTAssertNotNil(sh)
        let c = sh?.shadowColor?.usingColorSpace(.deviceRGB)
        XCTAssertEqual(c?.redComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(c?.alphaComponent ?? 0, 0.6)
        XCTAssertLessThanOrEqual(sh?.shadowBlurRadius ?? 99, 6, "tight shadow, not a halo")
    }

    func testLineChangeNeverShowsTwoLinesAtOnce() {
        let v = LyricsOverlayView(frame: NSRect(x: 0, y: 0, width: 1600, height: 300))
        v.layoutLines()
        v.show(current: "first line", next: "second line")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(v.visibleLineCount, 1)
        v.show(current: "second line", next: "third line")
        for _ in 0..<12 {                                   // sample through the change
            XCTAssertLessThanOrEqual(v.visibleLineCount, 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(v.visibleLineCount, 1)
        XCTAssertEqual(v.currentText, "second line")
    }
}
