// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import AppKit
import Metal
import QuartzCore

/// The bits of SyphonMetalServer we call. Syphon.framework (BSD-3-Clause) is optional: scripts/build_syphon.sh
/// builds it and make_app.sh embeds it in Contents/Frameworks. It is loaded at runtime, so the app builds and runs
/// without it (CI never needs Xcode's framework build).
@objc protocol SyphonMetalServerAPI: NSObjectProtocol {
    init?(name: String?, device: MTLDevice, options: [String: Any]?)
    func publishFrameTexture(_ texture: MTLTexture, onCommandBuffer cb: MTLCommandBuffer, imageRegion region: NSRect, flipped: Bool)
    func stop()
    var hasClients: Bool { get }
}

/// Publishes the final composited frame as the Syphon server "RAVE LIVE" (Resolume, VDMX, OBS, MadMapper...).
final class SyphonPublisher {
    private(set) static var loadError: String?
    private static let serverClass: AnyClass? = {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["RAVE_SYPHON_FRAMEWORK"] { paths.append(env) }
        if let fw = Bundle.main.privateFrameworksPath { paths.append(fw + "/Syphon.framework/Syphon") }
        paths.append(Bundle.main.bundlePath + "/../../vendor/Syphon.framework/Syphon")    // dev run from build/
        for p in paths where FileManager.default.fileExists(atPath: p) {
            guard dlopen(p, RTLD_NOW) != nil else { loadError = String(cString: dlerror()); continue }
            if let c = NSClassFromString("SyphonMetalServer") {
                class_addProtocol(c, SyphonMetalServerAPI.self)
                return c
            }
        }
        if loadError == nil { loadError = "Syphon.framework not bundled (run scripts/build_syphon.sh, then make_app.sh)" }
        return nil
    }()
    static var available: Bool { serverClass != nil }

    private let server: SyphonMetalServerAPI
    init?(device: MTLDevice, name: String = "RAVE LIVE") {
        guard let c = Self.serverClass, let t = c as? SyphonMetalServerAPI.Type,
              let s = t.init(name: name, device: device, options: nil) else { return nil }
        server = s
    }
    var hasClients: Bool { server.hasClients }
    func publish(_ tex: MTLTexture, cb: MTLCommandBuffer) {
        // flipped = "texture is upside down in Metal coordinates"; our drawables are upright (checked with the test client)
        server.publishFrameTexture(tex, onCommandBuffer: cb, imageRegion: NSRect(x: 0, y: 0, width: tex.width, height: tex.height), flipped: false)
    }
    func stop() { server.stop() }
}

/// Last stage of every frame, after the scene is drawn and before present: master brightness, Syphon publish,
/// a copy into the main window's preview while the visual runs on an output display, and test captures.
/// Overlays (HUD, cheat sheet) are AppKit views above the main window's Metal view, so they are never in this texture.
final class FrameOutput {
    let device: MTLDevice
    var brightness: Float = 1                 // master brightness 0...1 (MIDI knob / Controls menu)
    var syphon: SyphonPublisher?
    weak var preview: MTKViewLike?            // main window view that mirrors the output display
    var onCapture: ((CGImage) -> Void)?       // one-shot full-frame grab (UI screenshots)
    private(set) var publishedFrames = 0
    private var dimPipeline: MTLRenderPipelineState?

    init(device: MTLDevice) {
        self.device = device
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 dimv(uint i [[vertex_id]]) { float2 p = float2((i << 1) & 2, i & 2); return float4(p * 2 - 1, 0, 1); }
        fragment float4 dimf(constant float &b [[buffer(0)]]) { return float4(0, 0, 0, b); }
        """
        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "dimv"); d.fragmentFunction = lib.makeFunction(name: "dimf")
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true                       // dst * b: scales the frame without touching scene shaders
            ca.rgbBlendOperation = .add; ca.sourceRGBBlendFactor = .zero; ca.destinationRGBBlendFactor = .sourceAlpha
            ca.alphaBlendOperation = .add; ca.sourceAlphaBlendFactor = .zero; ca.destinationAlphaBlendFactor = .one
            dimPipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch { NSLog("RAVE LIVE: brightness pass unavailable: \(error)") }
    }

    /// `overlay` draws performer-only UI (Shader Lab errors, Tweak panel) onto the control surface after Syphon and the
    /// output display have taken their copy: onto the preview while an output display runs, else onto the main frame.
    func process(cb: MTLCommandBuffer, texture tex: MTLTexture, overlay: ((MTLRenderCommandEncoder, CGSize) -> Void)? = nil) {
        if brightness < 0.999, let p = dimPipeline {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex; rpd.colorAttachments[0].loadAction = .load; rpd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                var b = max(0, min(1, brightness))
                enc.setRenderPipelineState(p); enc.setFragmentBytes(&b, length: 4, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
            }
        }
        if let s = syphon { s.publish(tex, cb: cb); publishedFrames += 1 }
        if let pv = preview, let d = pv.previewDrawable(size: CGSize(width: tex.width, height: tex.height)),
           d.texture.pixelFormat == tex.pixelFormat, let blit = cb.makeBlitCommandEncoder() {
            let w = min(tex.width, d.texture.width), h = min(tex.height, d.texture.height)
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: d.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
            if let ov = overlay { Self.drawOverlay(ov, cb: cb, on: d.texture) }
            cb.present(d)
        } else if let ov = overlay, preview == nil {
            Self.drawOverlay(ov, cb: cb, on: tex)
        }
        if let cap = onCapture {
            onCapture = nil
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: tex.width, height: tex.height, mipmapped: false)
            d.storageMode = .shared
            guard let copy = device.makeTexture(descriptor: d), let blit = cb.makeBlitCommandEncoder() else { return }
            blit.copy(from: tex, to: copy); blit.endEncoding()
            cb.addCompletedHandler { _ in
                if let img = Self.cgImage(copy) { DispatchQueue.main.async { cap(img) } }
            }
        }
    }

    static func drawOverlay(_ ov: (MTLRenderCommandEncoder, CGSize) -> Void, cb: MTLCommandBuffer, on t: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = t; rpd.colorAttachments[0].loadAction = .load; rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        ov(enc, CGSize(width: t.width, height: t.height)); enc.endEncoding()
    }

    static func cgImage(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)   // BGRA
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The main window's view while it shows a preview of the output display.
protocol MTKViewLike: AnyObject {
    func previewDrawable(size: CGSize) -> CAMetalDrawable?
}
