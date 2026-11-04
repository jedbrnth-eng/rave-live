// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import MetalKit
import QuartzCore

/// An MTKView drawn from a display link that follows the screen the view is on (macOS 14+).
///
/// MTKView's own draw timer stays on one display. Measured on a MacBook Pro whose main display is a 144 Hz monitor:
/// the window on the built-in 120 Hz panel drew at 72 fps (the monitor's 144 / 2) although it asked for 120, and Send
/// to Display on that panel did the same, so frames were held for one refresh, then two, in turn. `NSView.displayLink`
/// tracks the view's screen. `isPaused` and `preferredFramesPerSecond` keep their MTKView meaning, so the covered-window
/// timer and Send to Display work unchanged. macOS 12-13, or env `RAVE_MTKVIEW_TIMER=1`, keep MTKView's timer.
class ScreenLinkedView: MTKView {
    /// False on macOS 12-13 and with `RAVE_MTKVIEW_TIMER=1` (A/B tests); set before the view joins a window.
    var allowLink: Bool = {
        if #available(macOS 14, *) { return ProcessInfo.processInfo.environment["RAVE_MTKVIEW_TIMER"] == nil }
        return false
    }()
    private var link: AnyObject?                  // CADisplayLink (macOS 14+)
    private var pausedFlag = false

    var usesDisplayLink: Bool { link != nil }
    /// MTKView's own timer (always paused while the link drives the view).
    var mtkTimerPaused: Bool { super.isPaused }
    var linkPaused: Bool? {
        guard #available(macOS 14, *), let l = link as? CADisplayLink else { return nil }
        return l.isPaused
    }
    var linkPreferredFPS: Float? {
        guard #available(macOS 14, *), let l = link as? CADisplayLink else { return nil }
        return l.preferredFrameRateRange.preferred
    }

    /// Exactly the target rate: the target is already a whole divisor of the refresh (`AppDelegate.targetFPS`).
    static func frameRateRange(fps: Int) -> CAFrameRateRange {
        let f = Float(max(1, fps))
        return CAFrameRateRange(minimum: f, maximum: f, preferred: f)
    }

    override var isPaused: Bool {
        get { link != nil ? pausedFlag : super.isPaused }
        set {
            guard #available(macOS 14, *), let l = link as? CADisplayLink else { super.isPaused = newValue; return }
            pausedFlag = newValue
            l.isPaused = newValue
        }
    }

    override var preferredFramesPerSecond: Int {
        didSet { if #available(macOS 14, *), let l = link as? CADisplayLink { l.preferredFrameRateRange = Self.frameRateRange(fps: preferredFramesPerSecond) } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startLink() }
    }

    /// Hands drawing from MTKView's timer to the screen-following link (once; the link then follows screen moves).
    func startLink() {
        guard link == nil, allowLink, #available(macOS 14, *) else { return }
        let paused = super.isPaused
        let l = displayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        l.preferredFrameRateRange = Self.frameRateRange(fps: preferredFramesPerSecond)
        l.isPaused = paused
        link = l
        pausedFlag = paused
        super.isPaused = true                     // MTKView's timer off: only the link draws
        enableSetNeedsDisplay = false
        l.add(to: .main, forMode: .common)        // .common: keeps drawing while a menu is open or the window resizes
    }

    deinit {
        if #available(macOS 14, *) { (link as? CADisplayLink)?.invalidate() }
    }
}

/// The link's target: holds the view weakly, so the link (which retains its target) never keeps the view alive.
private final class LinkTarget: NSObject {
    weak var view: MTKView?
    init(_ v: MTKView) { view = v }
    @objc func tick(_ link: AnyObject) { view?.draw() }
}
