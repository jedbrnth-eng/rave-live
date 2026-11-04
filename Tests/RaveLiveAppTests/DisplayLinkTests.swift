// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import XCTest
import MetalKit
@testable import RaveLiveApp

/// The main and output views draw from a display link that follows their screen (macOS 14+), while `isPaused` and
/// `preferredFramesPerSecond` keep their MTKView meaning for every caller (covered-window timer, Send to Display).
final class DisplayLinkTests: XCTestCase {
    private func makeView() throws -> ScreenLinkedView {
        let dev = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "needs a Metal device")
        return ScreenLinkedView(frame: NSRect(x: 0, y: 0, width: 64, height: 36), device: dev)
    }

    func testFrameRateRangeIsExactlyTheTarget() {
        for fps in [60, 72, 120, 144] {
            let r = ScreenLinkedView.frameRateRange(fps: fps)
            XCTAssertEqual(r.minimum, Float(fps)); XCTAssertEqual(r.maximum, Float(fps)); XCTAssertEqual(r.preferred, Float(fps))
        }
    }

    func testLinkDrivesTheViewAndPauseGoesToTheLink() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("display link needs macOS 14") }
        let v = try makeView()
        v.preferredFramesPerSecond = 72
        v.isPaused = false
        v.startLink()
        XCTAssertTrue(v.usesDisplayLink)
        XCTAssertTrue(v.mtkTimerPaused, "MTKView's own timer must stay off, or frames are drawn twice")
        XCTAssertFalse(v.isPaused); XCTAssertEqual(v.linkPaused, false)
        v.isPaused = true                                  // covered window / Send to Display pause the main view
        XCTAssertTrue(v.isPaused); XCTAssertEqual(v.linkPaused, true); XCTAssertTrue(v.mtkTimerPaused)
        v.isPaused = false
        XCTAssertFalse(v.isPaused); XCTAssertEqual(v.linkPaused, false); XCTAssertTrue(v.mtkTimerPaused)
    }

    func testPausedStateCarriesOverWhenTheLinkStarts() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("display link needs macOS 14") }
        let v = try makeView()
        v.isPaused = true
        v.startLink()
        XCTAssertTrue(v.isPaused); XCTAssertEqual(v.linkPaused, true)
    }

    func testTargetFrameRateReachesTheLink() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("display link needs macOS 14") }
        let v = try makeView()
        v.preferredFramesPerSecond = 72
        v.startLink()
        XCTAssertEqual(v.linkPreferredFPS, 72)
        v.preferredFramesPerSecond = 120                   // window moved to the 120 Hz panel (screenChanged)
        XCTAssertEqual(v.linkPreferredFPS, 120)
    }

    func testOptOutKeepsMTKViewsTimer() throws {
        let v = try makeView()
        v.allowLink = false                                // macOS 12-13, or RAVE_MTKVIEW_TIMER=1
        v.isPaused = false
        v.startLink()
        XCTAssertFalse(v.usesDisplayLink)
        XCTAssertFalse(v.mtkTimerPaused)
        v.isPaused = true
        XCTAssertTrue(v.mtkTimerPaused)
    }

    func testViewAndLinkAreFreedTogether() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("display link needs macOS 14") }
        weak var weakView: ScreenLinkedView?
        try autoreleasepool {
            let v = try makeView()
            v.startLink()
            XCTAssertTrue(v.usesDisplayLink)
            weakView = v
        }
        XCTAssertNil(weakView, "the link must not keep the view alive (each Send to Display open/close would leak a view)")
    }
}
