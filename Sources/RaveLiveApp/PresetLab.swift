// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import Metal
import UniformTypeIdentifiers

/// Per-preset look tweaks. Every field has a neutral default, so a tweak only changes what you touched.
struct LookTweak: Codable, Equatable {
    var speed: Float = 1        // motion speed; the beat clock only takes 0.25 / 0.5 / 1 / 2 so beat lock survives
    var hueShift: Float = 0     // 0..1 turns round the colour wheel
    var palette: Int = -1       // -1 = auto (new palette per visit), 0..6 = fixed
    var density: Float = 1      // 0.5..2: zooms the pattern out (more) or in (less)
    var feedback: Float = 0     // 0..0.95 extra trails over any preset
    var symmetry: Int = 0       // 0 = off, 2 = mirror, 3..12 = kaleidoscope folds
    var beat: Float = 1         // beat reactivity 0..2 (scales kick / beat / snare accents)

    init() {}
    init(from d: Decoder) throws {          // tolerant: missing keys keep their defaults, unknown keys are ignored
        let c = try d.container(keyedBy: CodingKeys.self)
        speed = (try? c.decodeIfPresent(Float.self, forKey: .speed)) ?? 1
        hueShift = (try? c.decodeIfPresent(Float.self, forKey: .hueShift)) ?? 0
        palette = (try? c.decodeIfPresent(Int.self, forKey: .palette)) ?? -1
        density = (try? c.decodeIfPresent(Float.self, forKey: .density)) ?? 1
        feedback = (try? c.decodeIfPresent(Float.self, forKey: .feedback)) ?? 0
        symmetry = (try? c.decodeIfPresent(Int.self, forKey: .symmetry)) ?? 0
        beat = (try? c.decodeIfPresent(Float.self, forKey: .beat)) ?? 1
        clamp()
    }
    mutating func clamp() {
        speed = Self.speeds.min { abs($0 - speed) < abs($1 - speed) } ?? 1
        hueShift = hueShift - floor(hueShift)
        palette = max(-1, min(6, palette))
        density = max(0.5, min(2, density))
        feedback = max(0, min(0.95, feedback))
        symmetry = symmetry == 1 ? 0 : max(0, min(12, symmetry))
        beat = max(0, min(2, beat))
    }
    static let speeds: [Float] = [0.25, 0.5, 1, 2]
    var isDefault: Bool { self == LookTweak() }
}

/// A shareable look: one preset + its tweaks, saved as JSON with the `.ravelook` extension.
struct RaveLook: Codable {
    var format = "ravelook"
    var version = 1
    var preset: String
    var params: LookTweak
    var name: String?
    var author: String?
    var app: String?
}

/// Draws an attributed string into a texture (CoreText via AppKit) and blends it over the frame. Re-rasterises only when the
/// text changes. Lives in the frame itself, so it shows in fullscreen and in `--snap` snapshots.
final class TextOverlay {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState?
    private var tex: MTLTexture?
    private var key = ""
    private(set) var pixelSize = CGSize.zero

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        let src = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct O { float4 pos [[position]]; float2 uv; };
        vertex O overt(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); O o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o; }
        fragment float4 ofrag(O in [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::linear); return t.sample(s, in.uv); }
        """#
        var p: MTLRenderPipelineState?
        if let lib = try? device.makeLibrary(source: src, options: nil) {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "overt"); d.fragmentFunction = lib.makeFunction(name: "ofrag")
            let a = d.colorAttachments[0]!
            a.pixelFormat = pixelFormat; a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            p = try? device.makeRenderPipelineState(descriptor: d)
        }
        pipeline = p
    }

    /// Lays out `text` in a box `width` px wide (height fits the text) with a translucent dark backing and a coloured edge.
    func update(_ text: NSAttributedString, width: CGFloat, accent: NSColor) {
        let k = "\(Int(width))|\(accent)|" + text.string + "\(text.length)"
        if k == key, tex != nil { return }
        key = k
        let pad: CGFloat = width * 0.03
        let bound = text.boundingRect(with: NSSize(width: width - 2 * pad, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = Int(width), h = Int(ceil(bound.height + 2 * pad))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let box = NSRect(x: 0, y: 0, width: w, height: h)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), xRadius: pad * 0.8, yRadius: pad * 0.8)
        NSColor(white: 0.03, alpha: 0.84).setFill(); path.fill()
        accent.withAlphaComponent(0.9).setStroke(); path.lineWidth = max(2, width * 0.003); path.stroke()
        text.draw(with: NSRect(x: pad, y: pad, width: CGFloat(w) - 2 * pad, height: CGFloat(h) - 2 * pad), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        if tex?.width != w || tex?.height != h { tex = device.makeTexture(descriptor: d) }
        tex?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        pixelSize = CGSize(width: w, height: h)
    }

    /// Blends the overlay at (x, y) px from the top-left of the target.
    func draw(_ e: MTLRenderCommandEncoder, x: Double, y: Double) {
        guard let pipeline, let tex else { return }
        e.setRenderPipelineState(pipeline)
        e.setViewport(MTLViewport(originX: x, originY: y, width: Double(tex.width), height: Double(tex.height), znear: 0, zfar: 1))
        e.setFragmentTexture(tex, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

/// Tweak panel (Shift+T in Classic Visuals), `.ravelook` save/open, Shader Lab error overlay and the Visuals menu.
final class PresetLab: NSObject {
    private(set) var tweaks: [String: LookTweak] = [:]
    var panelOpen = false
    private var row = 0
    private let persist = !CommandLine.arguments.contains("--lab-ephemeral")    // tests don't touch the user's saved tweaks
    private var panel: TextOverlay?
    private var errorBox: TextOverlay?
    private var message: (text: String, until: Double)?
    weak var visuals: VisualsRenderer?
    static let defaultsKey = "lookTweaks"
    static let rows = ["Speed", "Hue shift", "Palette", "Density", "Feedback", "Symmetry", "Beat react"]

    override init() {
        super.init()
        if persist, let d = UserDefaults.standard.data(forKey: Self.defaultsKey), let t = try? JSONDecoder().decode([String: LookTweak].self, from: d) { tweaks = t }
    }

    func tweak(for preset: String) -> LookTweak { tweaks[preset] ?? LookTweak() }
    func setTweak(_ t: LookTweak, for preset: String) {
        var t = t; t.clamp()
        tweaks[preset] = t.isDefault ? nil : t
        if persist, let d = try? JSONEncoder().encode(tweaks) { UserDefaults.standard.set(d, forKey: Self.defaultsKey) }
    }
    func flash(_ s: String, seconds: Double = 4) { message = (s, CACurrentMediaTime() + seconds); NSLog("Look: %@", s) }

    // MARK: keys
    /// Handles Shift+T, and the panel's keys while it is open. Returns true when the key was used.
    func handleKey(_ e: NSEvent, classic: Bool) -> Bool {
        let chars = e.characters ?? "", lower = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if classic && (chars == "T" || (lower == "t" && e.modifierFlags.contains(.shift))) { panelOpen.toggle(); return true }
        guard panelOpen && classic, let v = visuals else { return false }
        let scalar = chars.unicodeScalars.first.map { Int($0.value) } ?? 0
        var dir = 0
        switch (e.keyCode, scalar) {
        case (126, _), (_, 0xF700): row = (row + Self.rows.count - 1) % Self.rows.count; return true
        case (125, _), (_, 0xF701): row = (row + 1) % Self.rows.count; return true
        case (123, _), (_, 0xF702): dir = -1
        case (124, _), (_, 0xF703): dir = 1
        case (53, _): panelOpen = false; return true
        default:
            if lower == "r" { setTweak(LookTweak(), for: v.currentName); flash("reset " + v.currentName); return true }
            return false
        }
        var t = tweak(for: v.currentName)
        let f = Float(dir)
        switch row {
        case 0: let i = LookTweak.speeds.firstIndex(of: t.speed) ?? 2; t.speed = LookTweak.speeds[max(0, min(3, i + dir))]
        case 1: t.hueShift += 0.05 * f
        case 2: t.palette = (t.palette + 1 + dir + 8) % 8 - 1
        case 3: t.density *= dir > 0 ? 1.1 : 1 / 1.1
        case 4: t.feedback += 0.05 * f
        case 5: let steps = [0, 2, 3, 4, 5, 6, 8, 10, 12]; let i = steps.firstIndex(of: t.symmetry) ?? 0; t.symmetry = steps[max(0, min(steps.count - 1, i + dir))]
        default: t.beat += 0.1 * f
        }
        setTweak(t, for: v.currentName)
        return true
    }

    // MARK: overlays
    func drawOverlays(_ e: MTLRenderCommandEncoder, size: CGSize, device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let v = visuals else { return }
        let W = Double(size.width), H = Double(size.height), s = CGFloat(H / 1080)
        let now = CACurrentMediaTime()
        // Shader Lab error: always for the selected user shader, and for 12 s after any shader in the folder fails
        let lib = UserShaderLibrary.shared
        let failing = lib.entries.enumerated().filter { $0.element.error != nil }
            .filter { v.userIndex == $0.offset || now - $0.element.failedAt < 12 }.map(\.element)
        if let bad = failing.first {
            if errorBox == nil { errorBox = TextOverlay(device: device, pixelFormat: pixelFormat) }
            let t = NSMutableAttributedString()
            let title = NSFont.systemFont(ofSize: 34 * s, weight: .bold), mono = NSFont.monospacedSystemFont(ofSize: 27 * s, weight: .medium)
            t.append(NSAttributedString(string: "SHADER LAB · \(bad.name).metal didn't compile\n", attributes: [.font: title, .foregroundColor: NSColor(red: 1, green: 0.45, blue: 0.4, alpha: 1)]))
            for l in bad.errorLines {
                let isSrc = l.hasPrefix("    ")
                t.append(NSAttributedString(string: l + "\n", attributes: [.font: mono, .foregroundColor: isSrc ? NSColor(white: 0.75, alpha: 1) : NSColor.white]))
            }
            let keep = bad.pipeline != nil ? "Still showing the last version that worked. " : ""
            t.append(NSAttributedString(string: keep + "Fix it and save: it reloads by itself.", attributes: [.font: NSFont.systemFont(ofSize: 24 * s), .foregroundColor: NSColor(white: 0.7, alpha: 1)]))
            errorBox?.update(t, width: min(W * 0.8, 1500 * Double(s)), accent: NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1))
            errorBox?.draw(e, x: 28 * Double(s), y: H - Double(errorBox?.pixelSize.height ?? 0) - 60 * Double(s))
        }
        guard panelOpen || message.map({ now < $0.until }) == true else { return }
        if panel == nil { panel = TextOverlay(device: device, pixelFormat: pixelFormat) }
        let t = NSMutableAttributedString()
        let big = NSFont.systemFont(ofSize: 30 * s, weight: .heavy), mono = NSFont.monospacedSystemFont(ofSize: 26 * s, weight: .medium)
        let small = NSFont.systemFont(ofSize: 19 * s, weight: .regular)
        if panelOpen {
            let tw = tweak(for: v.currentName)
            t.append(NSAttributedString(string: "TWEAK  ·  \(v.currentName)\n", attributes: [.font: big, .foregroundColor: NSColor.white]))
            let vals = [tw.speed == 1 ? "1×" : String(format: "%g×", tw.speed), String(format: "%+.2f", tw.hueShift > 0.5 ? tw.hueShift - 1 : tw.hueShift),
                        tw.palette < 0 ? "auto" : "\(tw.palette + 1) of 7", String(format: "%.2f", tw.density), String(format: "%.2f", tw.feedback),
                        tw.symmetry == 0 ? "off" : tw.symmetry == 2 ? "mirror" : "\(tw.symmetry)-fold", String(format: "%.1f", tw.beat)]
            for (i, name) in Self.rows.enumerated() {
                let sel = i == row
                let line = (sel ? "› " : "  ") + name.padding(toLength: 12, withPad: " ", startingAt: 0) + vals[i] + "\n"
                t.append(NSAttributedString(string: line, attributes: [.font: mono, .foregroundColor: sel ? NSColor(red: 0.45, green: 1, blue: 0.85, alpha: 1) : NSColor(white: 0.85, alpha: 1)]))
            }
            t.append(NSAttributedString(string: "↑↓ pick  ←→ change  R reset  ⌘S save look  ⌘O open look  ⇧T close", attributes: [.font: small, .foregroundColor: NSColor(white: 0.65, alpha: 1)]))
            if let m = message, now < m.until { t.append(NSAttributedString(string: "\n" + m.text, attributes: [.font: small, .foregroundColor: NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1)])) }
        } else if let m = message {
            t.append(NSAttributedString(string: m.text, attributes: [.font: mono, .foregroundColor: NSColor.white]))
        }
        panel?.update(t, width: 700 * Double(s), accent: NSColor(red: 0.3, green: 0.95, blue: 0.8, alpha: 1))
        panel?.draw(e, x: W - Double(panel?.pixelSize.width ?? 0) - 28 * Double(s), y: 70 * Double(s))
    }

    // MARK: .ravelook files
    func look(forPreset name: String) -> RaveLook {
        let ver = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ver ?? "dev"
        return RaveLook(preset: name, params: tweak(for: name), name: name, author: nil, app: "RAVE LIVE " + appVer)
    }
    func save(to url: URL) throws {
        guard let v = visuals else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(look(forPreset: v.currentName)).write(to: url, options: .atomic)
        flash("saved " + url.lastPathComponent)
    }
    @discardableResult func open(url: URL) -> Bool {
        guard let v = visuals else { return false }
        guard let data = try? Data(contentsOf: url), let lk = try? JSONDecoder().decode(RaveLook.self, from: data), lk.format == "ravelook" else {
            flash("not a .ravelook file: " + url.lastPathComponent); return false
        }
        guard let idx = VisualsRenderer.presetNames.firstIndex(of: lk.preset) else {
            flash("this look needs the preset “\(lk.preset)” (a Shader Lab file?) — it isn't installed"); return false
        }
        setTweak(lk.params, for: lk.preset)
        v.preset = idx; v.autoCycle = false
        flash("opened look “\(lk.name ?? lk.preset)”")
        return true
    }

    /// Documents opened before the renderer existed (double-click at launch) wait here.
    nonisolated(unsafe) static var pendingOpen: [URL] = []
    func drainPending() {
        guard !Self.pendingOpen.isEmpty, visuals != nil else { return }
        let urls = Self.pendingOpen; Self.pendingOpen = []
        for u in urls { open(url: u) }
    }

    // MARK: test hooks (headless proofs): --tweak "speed=2,hue=0.25,palette=3,density=1.3,feedback=0.4,symmetry=6,beat=1.5"
    // and --look-roundtrip <file>: at 3 s save the current look, reset, open it again and log whether the params match.
    func applyCommandLine() {
        let a = CommandLine.arguments
        func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil } }
        if let s = arg("--tweak"), let v = visuals {
            var t = tweak(for: v.currentName)
            for kv in s.split(separator: ",") {
                let p = kv.split(separator: "="); guard p.count == 2, let x = Float(p[1]) else { continue }
                switch p[0] {
                case "speed": t.speed = x
                case "hue": t.hueShift = x
                case "palette": t.palette = Int(x)
                case "density": t.density = x
                case "feedback": t.feedback = x
                case "symmetry": t.symmetry = Int(x)
                case "beat": t.beat = x
                default: break
                }
            }
            setTweak(t, for: v.currentName)
        }
        if let want = arg("--lab-select") {           // test hook: keep selecting this Shader Lab file (it may appear later)
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let v = self?.visuals, let i = VisualsRenderer.presetNames.firstIndex(of: "Lab: " + want), v.preset != i else { return }
                v.preset = i; v.autoCycle = false
            }
        }
        if let path = arg("--look-roundtrip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let v = self.visuals else { return }
                let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                let name = v.currentName, before = self.tweak(for: name)
                do { try self.save(to: url) } catch { NSLog("ravelook round-trip FAILED: save %@", "\(error)"); return }
                self.setTweak(LookTweak(), for: name)
                let other = (v.preset + 1) % VisualsRenderer.builtinNames.count
                v.preset = other
                let ok = self.open(url: url)
                let after = self.tweak(for: v.currentName)
                let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
                let js = (try? enc.encode(after)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
                NSLog("ravelook round-trip %@: preset %@ -> %@ params %@", ok && after == before && v.currentName == name ? "OK" : "FAILED", name, v.currentName, js)
            }
        }
    }

    // MARK: menu
    func makeMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let m = NSMenu(title: "Visuals")
        func add(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key); it.keyEquivalentModifierMask = mods; it.target = self; m.addItem(it)
        }
        add("Tweak Panel (Classic Visuals)", #selector(menuTweak(_:)), "t", [.command, .shift])
        add("Save Look…", #selector(menuSave(_:)), "s")
        add("Open Look…", #selector(menuOpen(_:)), "o")
        m.addItem(.separator())
        add("Open Shader Folder…", #selector(menuFolder(_:)), "")
        add("Shader Lab Guide", #selector(menuGuide(_:)), "")
        item.submenu = m
        return item
    }
    /// Set by the app so menu actions can switch to Classic Visuals first.
    var onWantClassic: (() -> Void)?
    @objc func menuTweak(_ i: NSMenuItem) { onWantClassic?(); panelOpen.toggle() }
    @objc func menuSave(_ i: NSMenuItem) {
        guard let v = visuals else { return }
        let p = NSSavePanel()
        if let t = UTType(filenameExtension: "ravelook") { p.allowedContentTypes = [t] }
        p.nameFieldStringValue = v.currentName.replacingOccurrences(of: "/", with: "-") + ".ravelook"
        p.directoryURL = UserShaderLibrary.shared.folder.deletingLastPathComponent().appendingPathComponent("Looks")
        try? FileManager.default.createDirectory(at: p.directoryURL!, withIntermediateDirectories: true)
        if p.runModal() == .OK, let u = p.url { do { try save(to: u) } catch { flash("could not save: \(error.localizedDescription)") } }
    }
    @objc func menuOpen(_ i: NSMenuItem) {
        let p = NSOpenPanel()
        if let t = UTType(filenameExtension: "ravelook") { p.allowedContentTypes = [t, .json] }
        p.directoryURL = UserShaderLibrary.shared.folder.deletingLastPathComponent().appendingPathComponent("Looks")
        if p.runModal() == .OK, let u = p.url { onWantClassic?(); open(url: u) }
    }
    @objc func menuFolder(_ i: NSMenuItem) {
        let f = UserShaderLibrary.shared.folder
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f)
    }
    @objc func menuGuide(_ i: NSMenuItem) {
        if let u = URL(string: "https://github.com/jedbrnth-eng/rave-live/blob/main/docs/SHADERS.md") { NSWorkspace.shared.open(u) }
    }
}
