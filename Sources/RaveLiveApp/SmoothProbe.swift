// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation
import Metal

/// Smoothness probe (`--smoothlog <file>`, test only). Every frame the final composited image is box-filtered on the
/// GPU to a 64x36 luma grid and copied into a shared buffer; the completion handler compares it with the previous
/// frame on a background queue, so the render loop never waits. One tab-separated line per frame:
///   t dt phase beat locked luma dmean flick resid motion peak kick drop build mode scene preset trans
/// luma = mean luma 0..1, dmean = |change of the mean| (whole-frame flash), flick = mean |per-cell change|,
/// resid = per-block change left after the best +-2 cell shift (change motion doesn't explain: pops, flashes),
/// motion = mean best shift per block in cells (1 cell = 1/64 of the width), peak = brightest cell.
/// scripts/smooth_report.py turns the log into per-preset / per-transition statistics (docs/SMOOTHNESS.md).
final class SmoothProbe {
    static let gw = 64, gh = 36
    struct Meta { var t: Double; var dt: Float; var phase: Double; var beat: Int; var locked: Bool; var kick: Float; var drop: Float; var build: Float
        var mode: String; var scene: String; var preset: String; var trans: String }

    private let pipeline: MTLRenderPipelineState
    private let grid: MTLTexture
    private var buffers: [MTLBuffer] = []
    private var bufIndex = 0
    private let queue = DispatchQueue(label: "rave.smoothprobe", qos: .utility)
    private let path: String
    // `queue` only
    private var prev: [Float]?
    private var text = "t\tdt\tphase\tbeat\tlocked\tluma\tdmean\tflick\tresid\tmotion\tpeak\tkick\tdrop\tbuild\tmode\tscene\tpreset\ttrans\n"
    private var lastFlush = 0.0

    init?(device: MTLDevice, path: String) {
        self.path = path
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VO { float4 pos [[position]]; float2 uv; };
        vertex VO pv(uint i [[vertex_id]]) { float2 p = float2((i << 1) & 2, i & 2); VO o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o; }
        // 8x8 bilinear taps per cell ~ a box filter over the whole cell at 1080p
        fragment float pf(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 cell = float2(1.0 / 64.0, 1.0 / 36.0);
            float2 o = floor(in.uv / cell) * cell;
            float sum = 0;
            for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
                float3 c = t.sample(s, o + (float2(x, y) + 0.5) / 8.0 * cell).rgb;
                sum += dot(c, float3(0.2126, 0.7152, 0.0722));
            }
            return sum / 64.0;
        }
        """
        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "pv"); d.fragmentFunction = lib.makeFunction(name: "pf")
            d.colorAttachments[0].pixelFormat = .r32Float
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch { NSLog("RAVE LIVE: smooth probe unavailable: \(error)"); return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: Self.gw, height: Self.gh, mipmapped: false)
        td.usage = [.renderTarget]; td.storageMode = .private
        guard let g = device.makeTexture(descriptor: td) else { return nil }
        grid = g
        for _ in 0..<4 { if let b = device.makeBuffer(length: Self.gw * Self.gh * 4, options: .storageModeShared) { buffers.append(b) } }
        if buffers.count < 4 { return nil }
    }

    /// Encode the downsample of `source` (the finished frame) and log it when the GPU is done.
    func encode(cb: MTLCommandBuffer, source: MTLTexture, meta: Meta) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = grid; rpd.colorAttachments[0].loadAction = .dontCare; rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        e.setRenderPipelineState(pipeline); e.setFragmentTexture(source, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
        let buf = buffers[bufIndex]; bufIndex = (bufIndex + 1) % buffers.count
        guard let b = cb.makeBlitCommandEncoder() else { return }
        b.copy(from: grid, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: Self.gw, height: Self.gh, depth: 1),
               to: buf, destinationOffset: 0, destinationBytesPerRow: Self.gw * 4, destinationBytesPerImage: Self.gw * Self.gh * 4)
        b.endEncoding()
        cb.addCompletedHandler { [weak self] _ in
            let n = Self.gw * Self.gh
            let cur = Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float.self), count: n))
            self?.queue.async { self?.record(cur, meta) }
        }
    }

    private func record(_ cur: [Float], _ m: Meta) {
        let st = Self.compare(prev, cur, w: Self.gw, h: Self.gh)
        prev = cur
        text += String(format: "%.4f\t%.4f\t%.4f\t%d\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t%.3f\t%.4f\t%.3f\t%.3f\t%.3f\t", m.t, m.dt, m.phase, m.beat, m.locked ? 1 : 0,
                       st.luma, st.dmean, st.flick, st.resid, st.motion, st.peak, m.kick, m.drop, m.build)
        text += m.mode + "\t" + m.scene + "\t" + m.preset + "\t" + m.trans + "\n"
        if m.t - lastFlush > 2 { flush(); lastFlush = m.t }
    }
    /// Append what is pending (`queue` only; the file is created on the first flush).
    private func flush() {
        if handle == nil {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        }
        handle?.write(Data(text.utf8)); text = ""
    }
    private var handle: FileHandle?
    /// Write everything still pending (call before quitting).
    func finish() { queue.sync { flush() } }

    struct Stats: Equatable { var luma: Float; var dmean: Float; var flick: Float; var resid: Float; var motion: Float; var peak: Float }

    /// Frame-to-frame statistics of two luma grids (pure; unit-tested). Blocks of 8x6 cells are matched against the
    /// previous frame within +-2 cells; `resid` is the mean of each block's best match error, `motion` its mean shift.
    static func compare(_ prev: [Float]?, _ cur: [Float], w: Int, h: Int) -> Stats {
        var sum: Float = 0, peak: Float = 0
        for v in cur { sum += v; peak = max(peak, v) }
        let mean = sum / Float(max(1, cur.count))
        guard let p = prev, p.count == cur.count else { return Stats(luma: mean, dmean: 0, flick: 0, resid: 0, motion: 0, peak: peak) }
        var psum: Float = 0, flick: Float = 0
        for i in 0..<cur.count { psum += p[i]; flick += abs(cur[i] - p[i]) }
        let dmean = abs(mean - psum / Float(cur.count))
        flick /= Float(cur.count)
        let bw = 8, bh = 6, r = 2
        var residSum: Float = 0, motionSum: Float = 0, blocks: Float = 0
        var by = 0
        while by + bh <= h {
            var bx = 0
            while bx + bw <= w {
                var best = Float.greatestFiniteMagnitude, bestShift: Float = 0
                for dy in -r...r {
                    for dx in -r...r {
                        var e: Float = 0, n: Float = 0
                        for y in by..<(by + bh) {
                            let sy = y - dy
                            if sy < 0 || sy >= h { continue }
                            for x in bx..<(bx + bw) {
                                let sx = x - dx
                                if sx < 0 || sx >= w { continue }
                                e += abs(cur[y * w + x] - p[sy * w + sx]); n += 1
                            }
                        }
                        if n == 0 { continue }
                        e /= n
                        let shift = (Float(dx * dx + dy * dy)).squareRoot()
                        // prefer the smaller shift on (near) ties so a static image reports zero motion
                        if e < best - 1e-5 || (abs(e - best) <= 1e-5 && shift < bestShift) { best = e; bestShift = shift }
                    }
                }
                residSum += best; motionSum += bestShift; blocks += 1
                bx += bw
            }
            by += bh
        }
        return Stats(luma: mean, dmean: dmean, flick: flick, resid: residSum / max(1, blocks), motion: motionSum / max(1, blocks), peak: peak)
    }
}
