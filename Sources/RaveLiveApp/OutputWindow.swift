// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import MetalKit

/// "Output > Send to display": a borderless fullscreen window on a projector/second screen that shows only the visual.
/// While it is open the renderer draws into the output view (at that screen's resolution and refresh), and each frame is
/// copied into the main window, which becomes a preview with the controls. Unplugging the screen closes it and the main
/// window takes over again.
final class OutputWindow: NSObject, MTKViewDelegate {
    let window: NSWindow
    let view: MTKView
    let displayID: CGDirectDisplayID
    let screenName: String
    private weak var renderer: Renderer?
    private let mainView: MTKView
    private let preview: PreviewLayer
    private let savedAutoResize: Bool
    private var savedGravity: CALayerContentsGravity = .resize

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    init?(screen: NSScreen, renderer: Renderer, mainView: MTKView, sameScreenAsControls: Bool) {
        guard let dev = mainView.device else { return nil }
        self.renderer = renderer; self.mainView = mainView
        displayID = Self.displayID(screen); screenName = screen.localizedName
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        // Above the menu bar / Dock on a dedicated output screen; a normal window when it shares the controls' screen
        // (single-display setups), so Cmd-Tab and the main window stay reachable.
        window.level = sameScreenAsControls ? .normal : .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.title = "RAVE LIVE Output"
        view = ScreenLinkedView(frame: NSRect(origin: .zero, size: screen.frame.size), device: dev)   // paced by its own screen
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = mainView.colorPixelFormat
        view.framebufferOnly = false                      // Syphon + preview read the drawable
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.preferredFramesPerSecond = AppDelegate.targetFPS(screen.maximumFramesPerSecond)
        preview = PreviewLayer(view: mainView)
        savedAutoResize = mainView.autoResizeDrawable
        super.init()
        view.delegate = self
        window.contentView = view
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    var targetFPS: Int { view.preferredFramesPerSecond }

    func show(output: FrameOutput) {
        // hand the render loop to the output view; the main view just shows copies
        mainView.isPaused = true
        mainView.enableSetNeedsDisplay = false
        mainView.autoResizeDrawable = false
        output.preview = preview
        savedGravity = mainView.layer?.contentsGravity ?? .resize
        mainView.layer?.contentsGravity = .resizeAspect      // preview keeps the output's aspect (letterboxed)
        window.orderFrontRegardless()
        NSLog("RAVE LIVE: output window on %@ (%d x %d px, %d fps)", screenName, Int(view.drawableSize.width), Int(view.drawableSize.height), targetFPS)
    }

    func close(output: FrameOutput) {
        view.isPaused = true
        view.delegate = nil
        output.preview = nil
        window.orderOut(nil)
        mainView.autoResizeDrawable = savedAutoResize
        mainView.layer?.contentsGravity = savedGravity
        if savedAutoResize { mainView.drawableSize = mainView.convertToBacking(mainView.bounds.size) }
        mainView.isPaused = false
    }

    func screenChanged(_ s: NSScreen) {
        view.preferredFramesPerSecond = AppDelegate.targetFPS(s.maximumFramesPerSecond)
        window.setFrame(s.frame, display: true)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { renderer?.draw(in: view) }
}

/// The main window's Metal layer as a preview target: frames are blitted into its drawables at output size and the
/// layer scales them to the window.
/// The preview never blocks the output: the main window sits on another display's vsync, so when its drawables are still
/// queued the frame is simply not previewed (waiting in nextDrawable() halved the output frame rate).
final class PreviewLayer: MTKViewLike {
    private weak var view: MTKView?
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var skipped = 0
    init(view: MTKView) { self.view = view }
    func previewDrawable(size: CGSize) -> CAMetalDrawable? {
        guard ProcessInfo.processInfo.environment["RAVE_NO_PREVIEW"] == nil,
              let v = view, !v.isHidden, let layer = v.layer as? CAMetalLayer else { return nil }
        lock.lock(); let busy = inFlight >= 1; lock.unlock()
        if busy { skipped += 1; return nil }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let d = layer.nextDrawable() else { return nil }
        lock.lock(); inFlight += 1; lock.unlock()
        d.addPresentedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
        }
        return d
    }
}
