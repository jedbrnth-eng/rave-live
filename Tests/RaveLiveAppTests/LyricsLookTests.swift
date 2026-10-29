// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
import AppKit
@testable import RaveLiveApp

/// Jed (10-29 20:08, screenshot): "weird black circle around the lyrics", and the old and new line overlapped.
final class LyricsLookTests: XCTestCase {
    private func stage(_ style: LyricStyle = .clean) -> LyricsStageView {
        let v = LyricsStageView(frame: NSRect(x: 0, y: 0, width: 1600, height: 500))
        v.style = style
        return v
    }
    private func waitRaster(_ v: LyricsStageView, _ n: Int) {
        let deadline = Date().addingTimeInterval(3)
        while v.rasterCount < n && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// No layer paints a background or a shape: the only pixels are the glyph images.
    func testNoShapeBehindTheText() {
        let v = stage()
        v.setLine(index: 0, text: "made up words", words: WordTiming.estimate(text: "made up words", start: 0, nextStart: 2), next: "")
        waitRaster(v, 1)
        v.frame(t: 0.5, drive: LyricDrive(), now: 10)
        var layers: [CALayer] = []
        func walk(_ l: CALayer) { layers.append(l); l.sublayers?.forEach(walk) }
        walk(v.layer!)
        XCTAssertGreaterThan(layers.count, 4)
        for l in layers {
            XCTAssertNil(l.backgroundColor.flatMap { $0.alpha > 0 ? $0 : nil }, "a layer paints a background")
            XCTAssertNil(l.shadowColor.flatMap { l.shadowOpacity > 0 ? $0 : nil })
        }
    }

    /// Each glyph is white with a dark outline right next to it (readable on white frames), and nothing dark far away.
    func testGlyphsHaveATightDarkOutline() {
        let r = LineRaster.make(.init(words: ["O"], style: .clean, fontSize: 80, maxWidth: 2000, scale: 1, key: "t"))
        guard let img = r.units.first?.images[LineRaster.Kind.base.rawValue] else { return XCTFail("no image") }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var white = 0, darkOpaque = 0, cornerAlpha = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, a = Int(px[i + 3]), r = Int(px[i])
            if a > 200 && r > 230 { white += 1 }
            if a > 120 && r < 60 { darkOpaque += 1 }
            if (x < 3 || x >= w - 3) && (y < 3 || y >= h - 3) { cornerAlpha = max(cornerAlpha, a) }
        } }
        XCTAssertGreaterThan(white, 200, "white fill")
        XCTAssertGreaterThan(darkOpaque, 50, "dark outline/shadow next to the glyph")
        XCTAssertLessThan(cornerAlpha, 8, "nothing drawn out at the corners: no box")
    }

    /// Line change: the old line goes (120 ms) before the new one appears, so two lines never overlap.
    func testLineChangeNeverShowsTwoLinesAtOnce() {
        let v = stage()
        v.setLine(index: 0, text: "first line", words: WordTiming.estimate(text: "first line", start: 0, nextStart: 2), next: "")
        waitRaster(v, 1)
        for i in 0..<30 { v.frame(t: Double(i) / 60, drive: LyricDrive(), now: 10 + Double(i) / 60) }
        XCTAssertEqual(v.visibleLineCount, 1)
        v.setLine(index: 1, text: "second line", words: WordTiming.estimate(text: "second line", start: 2, nextStart: 4), next: "", now: 11)
        waitRaster(v, 2)
        var both = 0
        for i in 0..<40 {
            let now = 11 + Double(i) / 60
            v.frame(t: 2 + Double(i) / 60, drive: LyricDrive(), now: now)
            if v.visibleLineCount > 1 { both += 1 }
        }
        XCTAssertEqual(both, 0, "frames with two lines visible")
        XCTAssertEqual(v.currentText, "second line")
        XCTAssertEqual(v.visibleLineCount, 1)
    }

    /// Photosensitivity: with strobe effects off, kicks every frame can't make the glow jump.
    func testStrobeOffKeepsTheGlowSteady() {
        let v = stage(.neon)
        v.setLine(index: 0, text: "neon words", words: WordTiming.estimate(text: "neon words", start: 0, nextStart: 2), next: "")
        waitRaster(v, 1)
        var d = LyricDrive(); d.strobe = false; d.locked = true; d.bpm = 128; d.energy = 1
        var prev: Float = -1, maxJump: Float = 0
        for i in 0..<120 {
            d.kick = i % 2 == 0 ? 1 : 0; d.beatPhase = i % 2 == 0 ? 0 : 0.5
            v.frame(t: 0.3 + Double(i) / 60, drive: d, now: 20 + Double(i) / 60)
            let g = v.debugGlowOpacity
            if prev >= 0 { maxJump = max(maxJump, abs(g - prev)) }
            prev = g
        }
        XCTAssertLessThanOrEqual(maxJump, Float(LyricFX.maxRate(strobe: false) / 60) + 0.02)
    }
}
