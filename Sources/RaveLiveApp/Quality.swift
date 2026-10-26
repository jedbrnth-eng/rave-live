// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import Metal
import MetalKit

/// GPU quality tier. Apple silicon runs High (today's look); Intel iGPUs and other low-power GPUs get Low,
/// discrete AMD GPUs Medium. Picked automatically, overridable with View > Quality or `--quality`.
enum QualityTier: String, CaseIterable {
    case low, medium, high

    var title: String { ["Low", "Medium", "High"][Self.allCases.firstIndex(of: self)!] }
    /// AURORA particle count (env RAVE_PARTICLES still overrides).
    var particles: Int { [250_000, 500_000, 1_000_000][Self.allCases.firstIndex(of: self)!] }
    /// Drawable size relative to the view's pixels; the layer scales it up to fill the window.
    var renderScale: CGFloat { [0.6, 0.8, 1.0][Self.allCases.firstIndex(of: self)!] }
    /// High/Medium blur twice (two radii); Low blurs once.
    var fullBloom: Bool { self != .low }

    /// The tier the renderers are built with. Set by `QualityController.setUp` before the Renderer exists.
    nonisolated(unsafe) static var active: QualityTier = .high

    /// Best tier for this GPU, plus a short reason for logs and the menu.
    static func auto(for device: MTLDevice) -> (QualityTier, String) {
        let name = device.name
        if device.supportsFamily(.apple7) { return (.high, "\(name), Apple GPU") }      // M1 and newer
        if name.localizedCaseInsensitiveContains("intel") || device.isLowPower { return (.low, "\(name), integrated GPU") }
        return (.medium, "\(name), non-Apple GPU")                                        // AMD Radeon, VMs
    }

    var particlesEffective: Int { Int(ProcessInfo.processInfo.environment["RAVE_PARTICLES"] ?? "") ?? particles }
}

/// Owns the quality choice (auto or a fixed tier), applies it to the view and renderers, and builds View > Quality.
final class QualityController: NSObject {
    static let shared = QualityController()
    private static let defaultsKey = "quality"

    private(set) var choice = "auto"              // "auto" | QualityTier.rawValue
    private(set) var detected: (QualityTier, String) = (.high, "")
    private weak var view: MTKView?
    private weak var renderer: Renderer?
    private var fixedSize: CGSize?                // --width/--height test size (unscaled)
    private let menu = NSMenu(title: "Quality")

    var tier: QualityTier { QualityTier(rawValue: choice) ?? detected.0 }

    /// The slice that is running: "arm64", "x86_64", or "x86_64 (Rosetta)".
    static let cpuArch: String = {
        #if arch(x86_64)
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return rosetta ? "x86_64 (Rosetta)" : "x86_64"
        #else
        return "arm64"
        #endif
    }()

    /// Call before creating the Renderer. `override` is the `--quality` argument (not saved).
    func setUp(view: MTKView, override: String?) {
        self.view = view
        if let dev = view.device { detected = QualityTier.auto(for: dev) }
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "auto"
        let pick = (override ?? saved).lowercased()
        choice = (pick == "auto" || QualityTier(rawValue: pick) != nil) ? pick : "auto"
        QualityTier.active = tier
        if !view.autoResizeDrawable { fixedSize = view.drawableSize }
        NSLog("RAVE LIVE: quality %@ (%@; detected %@ for %@) · %@ · macOS %@", tier.rawValue, choice, detected.0.rawValue, detected.1,
              Self.cpuArch, ProcessInfo.processInfo.operatingSystemVersionString)
    }

    /// Call once the Renderer exists.
    func attach(_ r: Renderer) {
        renderer = r
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: NSView.frameDidChangeNotification, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        view?.postsFrameChangedNotifications = true
        apply()
    }

    private func apply() {
        let t = tier
        QualityTier.active = t
        if let r = renderer {
            if r.aurora?.particleCount != t.particlesEffective,
               let a = AuroraRenderer(device: r.device, pixelFormat: view?.colorPixelFormat ?? .bgra8Unorm, particles: t.particlesEffective) {
                r.aurora = a
            }
            r.aurora?.fullBloom = t.fullBloom
            r.metrics.event("quality:\(t.rawValue) (\(choice)) particles=\(t.particlesEffective) scale=\(t.renderScale) gpu=\(detected.1) cpu=\(Self.cpuArch)", at: CACurrentMediaTime())
        }
        viewChanged()
        rebuildMenu()
    }

    /// Keeps the drawable at view pixels x render scale. High leaves MTKView's own sizing alone (unchanged behaviour).
    @objc private func viewChanged() {
        guard let v = view else { return }
        let s = tier.renderScale
        if let fixed = fixedSize {
            v.drawableSize = CGSize(width: (fixed.width * s).rounded(), height: (fixed.height * s).rounded())
        } else if s >= 1 {
            if !v.autoResizeDrawable { v.drawableSize = v.convertToBacking(v.bounds).size; v.autoResizeDrawable = true }
        } else {
            v.autoResizeDrawable = false
            let px = v.convertToBacking(v.bounds).size
            v.drawableSize = CGSize(width: max(16, (px.width * s).rounded()), height: max(16, (px.height * s).rounded()))
        }
    }

    // MARK: View > Quality

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        menu.autoenablesItems = false
        item.submenu = menu
        rebuildMenu()
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let auto = NSMenuItem(title: "Auto (\(detected.0.title) for \(detected.1))", action: #selector(pick(_:)), keyEquivalent: "")
        auto.representedObject = "auto"
        menu.addItem(auto)
        menu.addItem(.separator())
        for t in QualityTier.allCases {
            let it = NSMenuItem(title: t.title, action: #selector(pick(_:)), keyEquivalent: "")
            it.representedObject = t.rawValue
            it.toolTip = "\(t.particles / 1000)k particles, \(Int(t.renderScale * 100))% resolution" + (t.fullBloom ? "" : ", light bloom")
            menu.addItem(it)
        }
        for it in menu.items where it.representedObject != nil {
            it.target = self
            it.state = (it.representedObject as? String) == choice ? .on : .off
        }
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let c = item.representedObject as? String else { return }
        choice = c
        UserDefaults.standard.set(c, forKey: Self.defaultsKey)
        apply()
    }
}
