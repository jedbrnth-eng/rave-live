// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import CoreText
import QuartzCore

/// One lyric line, rasterised once (off the main thread) into small images per word (or per letter for Bass wave):
/// `base` (white glyphs with a dark outline and a tight shadow), `lit` (the style's colour), `glow` (blurred colour) and
/// `shade` (a soft dark silhouette that rises on bright moments). Per frame only layer properties change.
struct LineRaster {
    enum Kind: Int, CaseIterable { case shade, glow, base, lit }
    struct Unit {
        var text: String
        var word: Int                 // word index this unit belongs to
        var rect: CGRect              // glyph box in block points (y up, origin bottom-left of the block)
        var images: [CGImage?]        // by Kind.rawValue
    }
    var units: [Unit]
    var wordRects: [CGRect]
    var size: CGSize
    var pad: CGFloat
    var fontSize: CGFloat
    var style: LyricStyle
    var key: String

    struct Spec {
        var words: [String]
        var style: LyricStyle
        var fontSize: CGFloat
        var maxWidth: CGFloat
        var scale: CGFloat
        var key: String
        /// Made on the main thread (AppKit font lookup); the raster thread only uses Core Text on it.
        var font: CTFont
    }

    /// Main thread only (NSFont / font descriptors).
    static func font(_ s: LyricStyle, size: CGFloat) -> CTFont {
        func named(_ n: String) -> CTFont? {
            let f = CTFontCreateWithName(n as CFString, size, nil)
            return (CTFontCopyPostScriptName(f) as String) == n ? f : nil
        }
        switch s {
        case .pop: return named("AvenirNextCondensed-Heavy") ?? NSFont.systemFont(ofSize: size, weight: .black)
        case .spectrum: return named("AvenirNextCondensed-Bold") ?? NSFont.systemFont(ofSize: size, weight: .heavy)
        case .neon, .wave:
            let base = NSFont.systemFont(ofSize: size, weight: s == .neon ? .heavy : .bold)
            if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .clean, .auto: return NSFont.systemFont(ofSize: size, weight: .bold)
        }
    }

    static func colors(_ s: LyricStyle, word: Int, of n: Int) -> (lit: CGColor, glow: CGColor) {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        let f = n > 1 ? CGFloat(word) / CGFloat(n - 1) : 0
        switch s {
        case .neon:                                               // magenta → cyan across the line
            return (c(1 - 0.8 * f, 0.25 + 0.65 * f, 0.85 + 0.15 * f), c(1 - 0.8 * f, 0.2 + 0.6 * f, 1))
        case .pop: return (c(1, 0.88, 0.18), c(1, 0.55, 0.1))
        case .spectrum:                                           // low band warm → high band cool, like an EQ
            let (r, g, b) = hsv(0.02 + 0.62 * f, 0.85, 1)
            return (c(r, g, b), c(r, g, b))
        case .wave: return (c(1, 1, 1), c(0.35, 1, 0.75))
        case .clean, .auto: return (c(1, 1, 1), c(0.65, 0.8, 1))
        }
    }

    static func hsv(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        guard h.isFinite else { return (v, v, v) }                 // Int(nan) traps; no caller passes one today
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i { case 0: return (v, t, p); case 1: return (q, v, p); case 2: return (p, v, t); case 3: return (p, q, v); case 4: return (t, p, v); default: return (v, p, q) }
    }

    /// Lays out and draws. Thread-safe (Core Text + bitmap contexts only).
    static func make(_ sp: Spec) -> LineRaster {
        var words = sp.style.uppercase ? sp.words.map { $0.uppercased() } : sp.words
        var fs = sp.fontSize
        var font = CTFontCreateCopyWithAttributes(sp.font, fs, nil, nil)
        func width(_ w: String, _ f: CTFont) -> CGFloat { CGFloat(CTLineGetTypographicBounds(Self.line(w, f), nil, nil, nil)) }
        func measure(_ f: CTFont) -> [CGFloat] { words.map { width($0, f) } }
        var widths = measure(font)
        var lay = LyricLayout.layout(widths: widths, space: fs * 0.28, maxWidth: sp.maxWidth, rowHeight: fs * 1.22)
        // A word wider than the lyric area (rows wrap between words only): shrink, never below half size. A few passes,
        // because the system font gets relatively wider at smaller sizes (optical sizing).
        let minFS = sp.fontSize * 0.5
        for _ in 0..<4 where lay.size.width > sp.maxWidth && lay.size.width > 0 && fs > minFS + 0.01 {
            fs = max(minFS, fs * min(0.99, sp.maxWidth / lay.size.width))
            font = CTFontCreateCopyWithAttributes(sp.font, fs, nil, nil)
            widths = measure(font)
            lay = LyricLayout.layout(widths: widths, space: fs * 0.28, maxWidth: sp.maxWidth, rowHeight: fs * 1.22)
        }
        if lay.size.width > sp.maxWidth {                          // still too wide at half size: cut it with an ellipsis
            for (i, w) in words.enumerated() where widths[i] > sp.maxWidth {
                let cs = Array(w)
                var lo = 0, hi = cs.count
                while lo < hi { let mid = (lo + hi + 1) / 2; if width(String(cs[..<mid]) + "…", font) <= sp.maxWidth { lo = mid } else { hi = mid - 1 } }
                words[i] = String(cs[..<lo]) + "…"
            }
            widths = measure(font)
            lay = LyricLayout.layout(widths: widths, space: fs * 0.28, maxWidth: sp.maxWidth, rowHeight: fs * 1.22)
        }
        let pad = (fs * (sp.style == .pop ? 0.42 : 0.34)).rounded(.up)
        let descent = CTFontGetDescent(font)
        var units: [Unit] = []
        for (i, w) in words.enumerated() {
            let r = lay.rects[i]
            if sp.style.perGlyph, case let line = Self.line(w, font), !Self.isRightToLeft(line) {    // RTL words stay one shaped unit (joined letters, right width)
                let ns = w as NSString
                var idx = 0
                while idx < ns.length {
                    let cr = ns.rangeOfComposedCharacterSequence(at: idx)
                    let x0 = CTLineGetOffsetForStringIndex(line, cr.location, nil)
                    let x1 = CTLineGetOffsetForStringIndex(line, cr.location + cr.length, nil)
                    let g = ns.substring(with: cr)
                    let rect = CGRect(x: r.minX + x0, y: r.minY, width: max(1, x1 - x0), height: r.height)
                    units.append(Unit(text: g, word: i, rect: rect, images: Self.draw(g, font: font, rect: rect, descent: descent, pad: pad, sp: sp, word: i, of: words.count)))
                    idx = cr.location + cr.length
                }
            } else {
                units.append(Unit(text: w, word: i, rect: r, images: Self.draw(w, font: font, rect: r, descent: descent, pad: pad, sp: sp, word: i, of: words.count)))
            }
        }
        return LineRaster(units: units, wordRects: lay.rects, size: lay.size, pad: pad, fontSize: fs, style: sp.style, key: sp.key)
    }

    static func isRightToLeft(_ line: CTLine) -> Bool {
        (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).contains { CTRunGetStatus($0).contains(.rightToLeft) }
    }

    private static func line(_ s: String, _ f: CTFont, color: CGColor? = nil, stroke: (CGColor, CGFloat)? = nil) -> CTLine {
        var a: [NSAttributedString.Key: Any] = [.font: f]
        if let color { a[.foregroundColor] = color } else { a[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true }
        if let (c, w) = stroke { a[.strokeColor] = c; a[.strokeWidth] = w }
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: a))
    }

    /// Images for one unit, each `rect` + `pad` on every side.
    private static func draw(_ s: String, font: CTFont, rect: CGRect, descent: CGFloat, pad: CGFloat, sp: Spec, word: Int, of n: Int) -> [CGImage?] {
        let w = Int(((rect.width + 2 * pad) * sp.scale).rounded(.up)), h = Int(((rect.height + 2 * pad) * sp.scale).rounded(.up))
        let fs = CTFontGetSize(font)
        let (litC, glowC) = colors(sp.style, word: word, of: n)
        let origin = CGPoint(x: pad, y: pad + (rect.height - fs * 1.22) / 2 + fs * 0.22 + descent * 0.35)
        func image(_ body: (CGContext) -> Void) -> CGImage? {
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: sp.scale, y: sp.scale)
            ctx.textPosition = origin
            body(ctx)
            return ctx.makeImage()
        }
        let outline: CGFloat = sp.style == .pop ? -9 : -4           // % of the font size; negative = fill + outline
        func text(_ ctx: CGContext, _ fill: CGColor, stroke: (CGColor, CGFloat)?, shadow: (CGColor, CGFloat, CGSize)?) {
            ctx.saveGState()
            if let (c, b, o) = shadow { ctx.setShadow(offset: o, blur: b * sp.scale, color: c) }
            ctx.textPosition = origin
            CTLineDraw(line(s, font, color: fill, stroke: stroke), ctx)
            ctx.restoreGState()
        }
        let tight = (CGColor(gray: 0, alpha: 0.8), max(2, fs * 0.06), CGSize(width: 0, height: -max(1, fs * 0.025) * sp.scale))
        let shade = image { ctx in text(ctx, CGColor(gray: 0, alpha: 0.55), stroke: (CGColor(gray: 0, alpha: 0.55), -18), shadow: (CGColor(gray: 0, alpha: 0.9), fs * 0.16, .zero)) }
        let glow = image { ctx in text(ctx, glowC.copy(alpha: 0.85)!, stroke: (glowC, -10), shadow: (glowC, fs * 0.28, .zero)) }
        let base: CGImage?
        switch sp.style {
        case .neon: base = image { ctx in text(ctx, CGColor(gray: 1, alpha: 0.18), stroke: (CGColor(gray: 1, alpha: 0.75), -3.5), shadow: tight) }
        default: base = image { ctx in text(ctx, CGColor(gray: 1, alpha: 1), stroke: (CGColor(gray: 0, alpha: 0.65), outline), shadow: tight) }
        }
        let lit: CGImage?
        switch sp.style {
        case .neon, .pop, .spectrum:
            let litStroke: CGColor = sp.style == .neon ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 0, alpha: 0.7)
            let litWidth: CGFloat = sp.style == .neon ? -2.5 : outline
            lit = image { ctx in text(ctx, litC, stroke: (litStroke, litWidth), shadow: tight) }
        default: lit = nil
        }
        return [shade, glow, base, lit]
    }
}

/// The lyrics on screen: an AppKit view over the main window (never reaches Syphon or the output display), drawn with
/// Core Animation layers. `frame(t:drive:)` runs once per rendered frame; it only moves, scales and fades layers.
final class LyricsStageView: NSView {
    var style: LyricStyle = .clean { didSet { if style != oldValue { restyle() } } }
    var position: LyricPosition = .lower
    var size = 1 { didSet { if size != oldValue { restyle() } } }

    /// Line change: old line out (`fadeOut`), then the new one in (`fadeIn`). Never two lines in the same spot.
    static let fadeOut = 0.12, fadeIn = 0.2
    /// Words not sung yet: dimmed (Apple-Music-like), but their dark shade stays full so they still read on white.
    static let upcoming = 0.55

    private final class Slot {
        let root = CALayer()
        var raster: LineRaster?
        var words: [TimedWord] = []
        var unitLayers: [[CALayer]] = []          // [unit][kind]
        var opacity: [[Double]] = []              // [unit][kind], slewed (photosensitivity)
        var shownAt = -1.0, leavingAt = -1.0
        var leaveFrom: Float = 1
        var text = ""
        var lineIndex = -1
    }
    private var current: Slot?
    private var leaving: [Slot] = []
    private let nextLayer = CALayer()
    private var nextText = ""
    private var nextRasterKey = ""
    private let queue = DispatchQueue(label: "ravelive.lyrics.raster", qos: .userInitiated)
    private var cache: [String: LineRaster] = [:]
    /// Raster jobs in flight: every caller waiting on a key gets the result (a prefetch and the line it becomes
    /// share one job). `gen` drops jobs started before a restyle, so they can't feed or clear the new style's work.
    private var pending: [String: (gen: Int, waiters: [(LineRaster) -> Void])] = [:]
    private var rasterGen = 0
    private var glowLevel = 0.0, shadeLevel = 0.0, beatLevel = 0.0
    private var bandLevels = [Double](repeating: 0, count: 5)
    private var bassLevel = 0.0, kickLevel = 0.0
    private var lastFrame = CACurrentMediaTime()
    private var frameDT = 1.0 / 60
    private var frameStrobe = true
    /// Every brightness change of every glyph layer goes through the photosensitivity slew (`LyricFX.slew`).
    private func setOpacity(_ s: Slot, _ ui: Int, _ ki: Int, _ l: CALayer, _ target: Double) {
        guard ui < s.opacity.count else { l.opacity = Float(target); return }
        let v = LyricFX.slew(s.opacity[ui][ki], toward: max(0, min(1, target)), dt: frameDT, strobe: frameStrobe)
        s.opacity[ui][ki] = v
        l.opacity = Float(v)
    }
    /// Test hook: the first unit's glow opacity.
    var debugGlowOpacity: Float { Float(current?.opacity.first?[LineRaster.Kind.glow.rawValue] ?? 0) }
    /// Test hook: total rasterisations (a frame must never trigger one).
    private(set) var rasterCount = 0
    private(set) var lastUnitCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        nextLayer.opacity = 0
        layer?.addSublayer(nextLayer)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var contentScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var hostHeight: CGFloat { window?.contentView?.bounds.height ?? max(bounds.height * 3, 600) }
    var fontSize: CGFloat {
        let base = max(14, hostHeight * [0.042, 0.056, 0.074][max(0, min(2, size))])
        return style == .pop ? base * 1.55 : (style == .spectrum ? base * 1.25 : base)
    }
    private var nextRowHeight: CGFloat { (style == .clean || style == .neon) ? fontSize * 0.55 * 1.5 : 0 }
    /// Where the line block is centred, in this view's coordinates (the hint line uses it when there are no lyrics).
    var lineCenterY: CGFloat {
        position == .center ? max(fontSize, (window?.contentView?.bounds.height ?? bounds.height * 1.25) / 2 - frame.minY) : nextRowHeight + fontSize * 0.75
    }
    var maxTextWidth: CGFloat { bounds.width * (style == .pop ? 0.7 : 0.8) }

    private func key(_ words: [String], _ style: LyricStyle) -> String {
        "\(style.rawValue)|\(Int(fontSize))|\(Int(maxTextWidth))|\(contentScale)|" + words.joined(separator: " ")
    }
    private func spec(_ words: [String], _ style: LyricStyle, fontScale: CGFloat = 1) -> LineRaster.Spec {
        LineRaster.Spec(words: words, style: style, fontSize: fontSize * fontScale, maxWidth: maxTextWidth, scale: contentScale,
                        key: key(words, style) + "|\(fontScale)", font: LineRaster.font(style, size: fontSize * fontScale))
    }

    /// Rasterise in the background (no main-thread text work at a line change); `done` runs on the main queue.
    private func raster(_ sp: LineRaster.Spec, done: ((LineRaster) -> Void)? = nil) {
        assert(Thread.isMainThread, "LyricsStageView is main-thread only (cache and pending aren't locked)")
        if let r = cache[sp.key] { done?(r); return }
        if pending[sp.key] != nil {                      // already being drawn: wait for that job
            if let done { pending[sp.key]?.waiters.append(done) }
            return
        }
        let gen = rasterGen
        pending[sp.key] = (gen, done.map { [$0] } ?? [])
        queue.async { [weak self] in
            let r = LineRaster.make(sp)
            DispatchQueue.main.async {
                guard let self, let job = self.pending[sp.key], job.gen == gen else { return }   // restyled meanwhile
                self.pending[sp.key] = nil
                self.rasterCount += 1
                if self.cache.count > 24 { self.cache.removeAll() }
                self.cache[sp.key] = r
                job.waiters.forEach { $0(r) }
            }
        }
    }

    /// Rasterise a line we will need soon (the next one), so its change costs nothing.
    func prepare(_ text: String) {
        let ws = WordTiming.words(text)
        guard !ws.isEmpty else { return }
        if style.chunked { return }                       // Pop rasterises its chunks as they come
        raster(spec(ws, style))
    }

    /// A new line (or nothing). `words` carries the timing (estimated + beat-snapped, or from word tags).
    func setLine(index: Int, text: String, words: [TimedWord], next: String, now: Double = CACurrentMediaTime()) {
        if let c = current, c.lineIndex == index, c.text == text { setNext(next); return }
        if let c = current { c.leavingAt = now; c.leaveFrom = c.root.opacity; leaving.append(c) }
        current = nil
        setNext(next)
        guard !words.isEmpty else { return }
        let s = Slot()
        s.text = text; s.words = words; s.lineIndex = index
        s.root.opacity = 0
        layer?.addSublayer(s.root)
        current = s
        if !style.chunked { build(s, ws: words.map(\.text)) }
    }

    private var chunkShown: Range<Int>?
    private func build(_ s: Slot, ws: [String], fontScale: CGFloat = 1) {
        let sty = style
        raster(spec(ws, sty, fontScale: fontScale)) { [weak self, weak s] r in
            guard let self, let s, self.current === s || s.raster == nil else { return }
            self.install(r, in: s)
        }
    }

    private func install(_ r: LineRaster, in s: Slot) {
        s.root.sublayers?.forEach { $0.removeFromSuperlayer() }
        s.unitLayers = []
        s.opacity = r.units.map { _ in [Double](repeating: 0, count: LineRaster.Kind.allCases.count) }
        s.raster = r
        let sc = contentScale
        for u in r.units {
            var ls: [CALayer] = []
            for k in LineRaster.Kind.allCases {
                let l = CALayer()
                l.contents = u.images[k.rawValue]
                l.contentsScale = sc
                l.contentsGravity = .resize
                l.isHidden = u.images[k.rawValue] == nil
                l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                l.bounds = CGRect(x: 0, y: 0, width: u.rect.width + 2 * r.pad, height: u.rect.height + 2 * r.pad)
                l.position = CGPoint(x: u.rect.midX, y: u.rect.midY)
                l.opacity = 0
                s.root.addSublayer(l)
                ls.append(l)
            }
            s.unitLayers.append(ls)
        }
        lastUnitCount = r.units.count
        placeRoot(s)
    }

    private func placeRoot(_ s: Slot) {
        guard let r = s.raster else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        s.root.bounds = CGRect(origin: .zero, size: r.size)
        let y: CGFloat = position == .center ? lineCenterY : nextRowHeight + r.size.height / 2 + fontSize * 0.1
        s.root.position = CGPoint(x: bounds.midX, y: y)
        CATransaction.commit()
    }

    private func setNext(_ n: String) {
        guard n != nextText else { return }
        nextText = n
        nextLayer.contents = nil
        let show = !n.isEmpty && (style == .clean || style == .neon)
        guard show else { return }
        let sp = LineRaster.Spec(words: [n], style: .clean, fontSize: fontSize * 0.5, maxWidth: .greatestFiniteMagnitude, scale: contentScale,
                                 key: "next|\(Int(fontSize))|\(contentScale)|" + n, font: LineRaster.font(.clean, size: fontSize * 0.5))
        nextRasterKey = sp.key
        raster(sp) { [weak self] r in
            guard let self, self.nextRasterKey == sp.key, let u = r.units.first else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.nextLayer.contents = u.images[LineRaster.Kind.base.rawValue]
            self.nextLayer.contentsScale = self.contentScale
            let w = min(self.bounds.width * 0.9, u.rect.width + 2 * r.pad)
            self.nextLayer.bounds = CGRect(x: 0, y: 0, width: w, height: u.rect.height + 2 * r.pad)
            self.nextLayer.position = CGPoint(x: self.bounds.midX, y: self.position == .center ? self.lineCenterY - self.fontSize * 1.6 : u.rect.height / 2 + 2)
            CATransaction.commit()
        }
    }

    private func restyle() {
        cache.removeAll(); pending.removeAll(); rasterGen += 1
        let c = current
        current = nil
        leaving.forEach { $0.root.removeFromSuperlayer() }; leaving = []
        c?.root.removeFromSuperlayer()
        nextText = "\u{1}"; nextLayer.contents = nil
        chunkShown = nil
        if let c { setLine(index: c.lineIndex, text: c.text, words: c.words, next: "") }
    }

    func clear() {
        let now = CACurrentMediaTime()
        if let c = current { c.leavingAt = now; c.leaveFrom = c.root.opacity; leaving.append(c) }
        current = nil
        setNext("")
    }

    func relayout() {
        cache.removeAll()
        if let c = current { let w = c.words; let t = c.text; let i = c.lineIndex; current = nil; c.root.removeFromSuperlayer(); setLine(index: i, text: t, words: w, next: nextText == "\u{1}" ? "" : nextText) }
        else { let n = nextText; nextText = "\u{1}"; setNext(n) }
    }

    // MARK: per frame

    /// `t` = the song time heard now (seconds), `drive` = the music this frame.
    func frame(t: Double, drive d: LyricDrive, now: Double = CACurrentMediaTime()) {
        let dt = max(0, min(0.1, now - lastFrame)); lastFrame = now
        let strobe = d.strobe
        frameDT = dt; frameStrobe = strobe
        // smoothed, photosensitivity-limited levels (brightness may only change at LyricFX.maxRate)
        glowLevel = LyricFX.slew(glowLevel, toward: LyricFX.glow(energy: d.energy, drop: d.drop), dt: dt, strobe: strobe)
        beatLevel = LyricFX.slew(beatLevel, toward: LyricFX.beatPulse(phase: d.beatPhase, locked: d.locked), dt: dt, strobe: strobe)
        shadeLevel = LyricFX.slew(shadeLevel, toward: Double(min(1, 0.7 + 0.3 * d.energy + 0.3 * d.drop)), dt: dt, strobe: false)
        let k = 1 - exp(-dt / 0.06)
        for i in 0..<5 { bandLevels[i] += (Double(d.bands.count > i ? d.bands[i] : 0) - bandLevels[i]) * k }
        bassLevel += (Double(d.bass) - bassLevel) * k
        kickLevel = Double(d.kick)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        // leaving lines: fade out fast, drift up a touch, then go
        leaving.removeAll { s in
            let a = 1 - (now - s.leavingAt) / Self.fadeOut
            if a <= 0 { s.root.removeFromSuperlayer(); return true }
            s.root.opacity = Float(a) * s.leaveFrom
            return false
        }
        let blocked = leaving.contains { now - $0.leavingAt < Self.fadeOut }
        if let s = current, s.raster != nil || style.chunked {
            if s.shownAt < 0 && !blocked { s.shownAt = now }
            let a = s.shownAt < 0 ? 0 : min(1, (now - s.shownAt) / Self.fadeIn)
            s.root.opacity = Float(LyricFX.easeOut(a))
            animate(s, t: t, d: d)
        }
        let nextA: Float = (current?.shownAt ?? -1) >= 0 && !nextText.isEmpty ? 0.55 : 0
        nextLayer.opacity = nextA
        CATransaction.commit()
    }

    private func animate(_ s: Slot, t: Double, d: LyricDrive) {
        if style.chunked { animatePop(s, t: t, d: d); return }
        guard let r = s.raster else { return }
        let fs = r.fontSize
        let breath = 1 + 0.02 * beatLevel
        s.root.setAffineTransform(CGAffineTransform(scaleX: breath, y: breath))
        let punch = LyricFX.punch(kick: Float(kickLevel), bass: Float(bassLevel), strobe: d.strobe)
        let activeWord = s.words.lastIndex { t >= $0.start }
        let activeX = activeWord.map { r.wordRects[$0].midX } ?? -1e9
        for (ui, u) in r.units.enumerated() {
            guard ui < s.unitLayers.count else { break }
            let w = s.words[min(u.word, s.words.count - 1)]
            let p = LyricFX.progress(t, w)
            let started = t >= w.start
            let since = t - w.start, after = t - w.end
            let env = started ? LyricFX.easeOut(since / 0.15) * (1 - LyricFX.easeOut(max(0, after) / 0.35)) : 0
            let on = started ? Self.upcoming + (1 - Self.upcoming) * LyricFX.easeOut(since / 0.22) : Self.upcoming
            var dx = 0.0, dy = 0.0, sx = 1.0, sy = 1.0
            var baseA = on, litA = 0.0, glowA = 0.0, litW = 1.0
            switch style {
            case .clean, .auto:
                dy = Double(fs) * 0.05 * env
                sx = 1 + 0.035 * env + punch * env; sy = sx
                glowA = 0.35 * glowLevel * env
            case .neon:
                baseA = 1
                litA = started ? 1 : 0
                litW = p
                glowA = started ? glowLevel * (0.55 + 0.45 * beatLevel) * (0.35 + 0.65 * max(env, p < 1 ? 1 : 0.5)) : 0
                sx = 1 + punch * env; sy = sx
                dy = Double(fs) * 0.03 * env
            case .wave:
                let x = Double(u.rect.midX)
                let lambda = Double(fs) * 5.5
                let phase = d.locked ? d.beatPhase : (t * 0.5).truncatingRemainder(dividingBy: 1)
                let amp = Double(fs) * (0.05 + 0.24 * min(1, bassLevel * 1.4))
                let ripple = Double(fs) * 0.3 * kickLevel * exp(-pow((x - Double(activeX)) / (Double(fs) * 2.5), 2)) * (d.strobe ? 1 : 0.5)
                dy = amp * sin(2 * Double.pi * (x / lambda - phase)) + ripple
                glowA = glowLevel * (started ? 0.7 : 0.25)
                sx = 1 + 0.04 * env; sy = sx
            case .spectrum:
                let n = max(1, s.words.count)
                let band = min(4, u.word * 5 / n)
                let lv = min(1, bandLevels[band] * 1.3)
                sy = 0.7 + 0.75 * lv
                sx = 1 + 0.03 * env
                dy = Double(u.rect.height) * (sy - 1) / 2       // grow up from the baseline like a meter bar
                baseA = 0; litA = on
                glowA = glowLevel * lv * (started ? 0.9 : 0.35)
            case .pop: break
            }
            let ls = s.unitLayers[ui]
            let pos = CGPoint(x: u.rect.midX + CGFloat(dx), y: u.rect.midY + CGFloat(dy))
            let tr = CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy))
            for (ki, l) in ls.enumerated() where !l.isHidden {
                l.position = pos
                l.setAffineTransform(tr)
                switch LineRaster.Kind(rawValue: ki)! {
                case .shade: setOpacity(s, ui, ki, l, shadeLevel)
                case .glow: setOpacity(s, ui, ki, l, glowA)
                case .base: setOpacity(s, ui, ki, l, baseA)
                case .lit:
                    setOpacity(s, ui, ki, l, litA)
                    if style == .neon { wipe(l, unitRect: u.rect, pad: r.pad, fraction: litW) }
                }
            }
        }
    }

    /// Karaoke fill without masks (masks don't show in window snapshots): crop the lit layer to the sung part.
    private func wipe(_ l: CALayer, unitRect: CGRect, pad: CGFloat, fraction: Double) {
        let full = unitRect.width + 2 * pad
        let shown = pad + unitRect.width * CGFloat(max(0, min(1, fraction)))
        let f = fraction >= 1 ? full : shown
        l.contentsRect = CGRect(x: 0, y: 0, width: f / full, height: 1)
        l.bounds = CGRect(x: 0, y: 0, width: f, height: unitRect.height + 2 * pad)
        l.anchorPoint = CGPoint(x: 0, y: 0.5)
        l.position = CGPoint(x: l.position.x - (unitRect.width / 2 + pad), y: l.position.y)
    }

    // Pop: the chunk holding the current word, each word springing in as it is sung.
    private func animatePop(_ s: Slot, t: Double, d: LyricDrive) {
        let chunks = WordTiming.chunks(s.words, size: 3)
        guard let ci = chunks.lastIndex(where: { t >= s.words[$0.lowerBound].start - 0.12 }) ?? chunks.indices.first else { return }
        let ch = chunks[ci]
        if chunkShown != ch || s.raster == nil {
            if chunkShown != nil && chunkShown != ch {     // chunk change: the old chunk goes like a line
                let old = Slot(); old.root.addSublayer(CALayer())
                if let subs = s.root.sublayers { for l in subs { l.removeFromSuperlayer(); old.root.addSublayer(l) } }
                old.root.bounds = s.root.bounds; old.root.position = s.root.position; old.root.opacity = s.root.opacity
                old.root.setAffineTransform(s.root.affineTransform())
                old.leavingAt = lastFrame; old.leaveFrom = s.root.opacity; layer?.addSublayer(old.root); leaving.append(old)
                s.unitLayers = []; s.raster = nil
                s.shownAt = -1; s.root.opacity = 0                 // the next chunk waits for the old one to go
            }
            chunkShown = ch
            let ws = s.words[ch].map(\.text)
            let sp = spec(ws, .pop)
            if let r = cache[sp.key] { install(r, in: s) } else {
                raster(sp) { [weak self, weak s] r in
                    guard let self, let s, self.current === s, self.chunkShown == ch else { return }
                    self.install(r, in: s)
                }
                return
            }
        }
        guard let r = s.raster else { return }
        let punch = LyricFX.punch(kick: Float(kickLevel), bass: Float(bassLevel), strobe: d.strobe)
        let tilt = -0.05
        s.root.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(tilt)).scaledBy(x: CGFloat(1 + punch), y: CGFloat(1 + punch)))
        for (ui, u) in r.units.enumerated() where ui < s.unitLayers.count {
            let w = s.words[ch.lowerBound + u.word]
            let since = t - w.start
            let sp = since > 0 ? LyricFX.spring(since, freq: 2.4, damping: 0.42) : 0
            let scale = since > 0 ? 0.55 + 0.45 * sp : 0.55
            let active = since >= 0 && t < w.end + 0.05
            for (ki, l) in s.unitLayers[ui].enumerated() where !l.isHidden {
                l.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                let vis = since > 0 ? 1.0 : 0
                switch LineRaster.Kind(rawValue: ki)! {
                case .shade: setOpacity(s, ui, ki, l, vis * shadeLevel)
                case .glow: setOpacity(s, ui, ki, l, active ? vis * glowLevel * (0.5 + 0.5 * beatLevel) : 0)
                case .base: setOpacity(s, ui, ki, l, active ? 0 : vis)
                case .lit: setOpacity(s, ui, ki, l, active ? vis : 0)
                }
            }
        }
    }

    // MARK: test + snapshot hooks

    var currentText: String { current?.text ?? "" }
    /// Lines with any opacity on screen (never more than one, apart from the old one's 120 ms fade-out).
    var visibleLineCount: Int { (current.map { $0.root.opacity > 0.01 ? 1 : 0 } ?? 0) + leaving.filter { $0.root.opacity > 0.01 }.count }
    var debugGeometry: String {
        guard let c = current else { return "no line" }
        return String(format: "root pos %.0f,%.0f bounds %.0fx%.0f opacity %.2f units %d words %d font %.1f", c.root.position.x, c.root.position.y,
                      c.root.bounds.width, c.root.bounds.height, c.root.opacity, c.unitLayers.count, c.words.count, c.raster?.fontSize ?? 0)
    }
    var lineScale: Double { Double(current?.root.affineTransform().a ?? 1) }

    /// The overlay as drawn now, for `shot=` window snapshots (`cacheDisplay` doesn't draw layer contents).
    func snapshotImage(scale: CGFloat) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let l = layer else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        l.render(in: ctx)
        return ctx.makeImage()
    }
}
