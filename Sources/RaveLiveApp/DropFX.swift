// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Metal
import QuartzCore

/// The festival drop, on top of every mode: in the silence after a build the lights dip ("the breath"), and on the
/// drop kick four confetti cannons fire metallic gold, silver and champagne paper that tumbles down over the next
/// 10-15 s, catching the light as it turns.
///
/// Each piece flies a closed-form path (launch speed, drag towards a slow terminal fall, sideways flutter), so the
/// whole burst is a function of the time since the drop: nothing to simulate or store, and an offscreen render is
/// repeatable. The tilt-and-wobble model of falling paper follows canvas-confetti by Kiril Vatev (ISC licence);
/// no code was copied.
final class DropFX {
    struct Burst: Equatable { var time: Double; var number: Int; var fromStage: Bool }
    /// The last burst (nil until the first drop).
    private(set) var burst: Burst?
    /// Settings → "Festival drop". Off = no breath and no confetti.
    var enabled = true
    /// Seconds a burst stays in the air (the last pieces fade out by then).
    static let airTime = 15.0
    /// Pieces per burst: Chill keeps it light, Wild fills the sky.
    static func pieces(_ i: Renderer.Intensity) -> Int { [900, 1800, 2600][i.rawValue] }
    /// How far the lights dip in the breath before a drop.
    static func breathDepth(_ i: Renderer.Intensity) -> Float { [0.55, 0.75, 0.9][i.rawValue] }

    private let confetti: MTLRenderPipelineState
    private let dim: MTLRenderPipelineState
    private var u = [Float](repeating: 0, count: 12)

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        do { (confetti, dim) = try Self.pipelines(device: device, pixelFormat: pixelFormat) } catch { NSLog("Drop shader error: \(error)"); return nil }
    }

    /// Confetti (premultiplied alpha, glints add light) and the breath (multiplies the frame down). Also run by ShaderWarmup.
    static func pipelines(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> (MTLRenderPipelineState, MTLRenderPipelineState) {
        let lib = try device.makeLibrary(source: dropShaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "confettiVert"); d.fragmentFunction = lib.makeFunction(name: "confettiFrag")
        let c = d.colorAttachments[0]!
        c.pixelFormat = pixelFormat; c.isBlendingEnabled = true
        c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
        let confetti = try device.makeRenderPipelineState(descriptor: d)
        d.vertexFunction = lib.makeFunction(name: "breathVert"); d.fragmentFunction = lib.makeFunction(name: "breathFrag")
        c.sourceRGBBlendFactor = .zero; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        return (confetti, try device.makeRenderPipelineState(descriptor: d))
    }

    /// Call every frame. A new drop fires the cannons; where they stand depends on the scene it cuts to.
    func update(dropStarted: Bool, now: Double, fromStage: Bool) {
        if dropStarted { burst = Burst(time: now, number: (burst?.number ?? 0) + 1, fromStage: fromStage) }
    }

    /// Shader inputs for this frame, or nil when there is nothing to draw.
    /// u: 0-1 size, 2 seconds since the burst, 3 burst number, 4 pieces, 5 kick, 6 breath, 7 hue, 8 launch height, 9 rise
    func uniforms(now: Double, size: CGSize, kick: Float, gap: Float, hue: Float, intensity: Renderer.Intensity) -> [Float]? {
        guard enabled else { return nil }
        let since = burst.map { now - $0.time } ?? .infinity
        let breath = gap * Self.breathDepth(intensity)
        guard since < Self.airTime || breath > 0.002 else { return nil }
        u[0] = Float(size.width); u[1] = Float(size.height)
        u[2] = since < Self.airTime ? Float(since) : -1
        u[3] = Float((burst?.number ?? 0) % 997)
        u[4] = Float(Self.pieces(intensity))
        u[5] = kick; u[6] = breath; u[7] = hue
        // on the Stage the cannons sit on the deck front; over the other scenes they fire from just below the frame
        let stage = burst?.fromStage ?? false
        u[8] = stage ? -0.10 : -1.08
        u[9] = stage ? 0.95 : 1.75
        return u
    }

    /// Draws onto the finished frame (before Syphon / the output display take it).
    func encode(cb: MTLCommandBuffer, target: MTLTexture, uniforms u: [Float]) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .load; rp.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setVertexBytes(u, length: u.count * 4, index: 0); e.setFragmentBytes(u, length: u.count * 4, index: 0)
        if u[6] > 0.002 {
            e.setRenderPipelineState(dim)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if u[2] >= 0 {
            e.setRenderPipelineState(confetti)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Int(u[4]))
        }
        e.endEncoding()
    }
}

let dropShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

// u: 0-1 size, 2 seconds since the burst (<0: none), 3 burst number, 4 pieces, 5 kick, 6 breath, 7 hue,
//    8 launch height (p-space, y up), 9 rise to the top of the arc

struct BOut { float4 pos [[position]]; };
vertex BOut breathVert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    BOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); return o;
}
// the frame is multiplied by (1 - alpha): the lights hold their breath
fragment float4 breathFrag(BOut in [[stage_in]], constant float *u [[buffer(0)]]) { return float4(0.0, 0.0, 0.0, clamp(u[6], 0.0, 0.95)); }

struct CVOut {
    float4 pos [[position]];
    float2 q;          // -1..1 across the piece
    float3 col;
    float glint;
    float alpha;
};

float ch(float n) { return fract(sin(n) * 43758.5453); }

// A paper piece launched at v0 slows under drag k towards a slow terminal fall vt (closed form, no state).
float2 flight(float2 v0, float2 vt, float k, float t) { return vt * t + (v0 - vt) * (1.0 - exp(-k * t)) / k; }

vertex CVOut confettiVert(uint vid [[vertex_id]], uint iid [[instance_id]], constant float *u [[buffer(0)]]) {
    CVOut o;
    o.pos = float4(0.0, 0.0, 2.0, 1.0); o.q = float2(0.0); o.col = float3(0.0); o.glint = 0.0; o.alpha = 0.0;
    float aspect = u[0] / max(u[1], 1.0);
    float n = float(iid) * 1.618 + u[3] * 97.31;
    float r0 = ch(n * 12.9898 + 1.0), r1 = ch(n * 78.233 + 2.0), r2 = ch(n * 37.719 + 3.0), r3 = ch(n * 93.989 + 4.0);
    float r4 = ch(n * 51.413 + 5.0), r5 = ch(n * 27.127 + 6.0), r6 = ch(n * 63.731 + 7.0), r7 = ch(n * 19.391 + 8.0);
    float r8 = ch(n * 45.164 + 9.0), r9 = ch(n * 83.155 + 10.0), r10 = ch(n * 31.877 + 11.0), r11 = ch(n * 71.463 + 12.0);
    float t = u[2] - r0 * 0.28;                    // the volley leaves the barrels over 0.28 s
    if (u[2] < 0.0 || t <= 0.0) return o;

    // four cannons; the outer pair tilts outwards so the cloud spans the whole width
    int cannon = int(iid % 4u);
    float cx = (cannon == 0 ? -0.80 : cannon == 1 ? -0.27 : cannon == 2 ? 0.27 : 0.80) * aspect;
    float tilt = (cx > 0.0 ? 1.0 : -1.0) * (abs(cx) > 0.5 * aspect ? 0.30 : 0.10);
    float ang = tilt + (r1 - 0.5) * 1.25;
    // paper: heavy drag (the burst is over in about half a second); pieces differ in drag and fall speed, so the
    // volley opens into a cloud instead of travelling as one band
    float k = 2.4 + 4.6 * r5;
    float rise = u[9] * (0.55 + 0.75 * r2);
    float2 v0 = float2(sin(ang), cos(ang)) * rise * k;
    float2 vt = float2(0.06 * (r4 - 0.5), -(0.08 + 0.22 * r3 * r3));
    float2 pos = float2(cx, u[8]) + flight(v0, vt, k, t);
    float settle = 1.0 - exp(-k * t);
    pos.x += settle * (0.012 + 0.035 * r6) * sin(t * (1.6 + 2.6 * r7) + r8 * 6.2832);   // flutter
    // depth: one piece in nine is close to the camera, bigger and a little softer
    bool nearCam = r9 < 0.11;
    float size = (0.0048 + 0.0055 * r10) * (nearCam ? 2.7 : 1.0);
    // tumble: spin in the frame plus the flip that turns the face to the light and away
    float spin = r8 * 6.2832 + t * (1.5 + 4.5 * r1) * (r2 > 0.5 ? 1.0 : -1.0);
    float flip = cos(r3 * 6.2832 + t * (2.8 + 6.5 * r4));
    float2 corner = float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : -1.0, (vid == 2 || vid == 4 || vid == 5) ? 1.0 : -1.0);
    float2 c = corner * float2(size, size * 1.55 * max(0.18, abs(flip)));
    float cs = cos(spin), sn = sin(spin);
    float2 pp = pos + float2(c.x * cs - c.y * sn, c.x * sn + c.y * cs);
    o.pos = float4(pp.x / aspect, pp.y, 0.0, 1.0);
    o.q = corner;

    // metallic gold, silver and champagne; one piece in ten takes the scene's colour
    float3 gold = float3(0.96, 0.72, 0.30), silver = float3(0.82, 0.86, 0.93), champagne = float3(1.0, 0.87, 0.66);
    float3 accent = 0.5 + 0.5 * cos(6.28318 * (u[7] + float3(0.0, 0.33, 0.67)));
    float3 base = r11 < 0.42 ? gold : r11 < 0.72 ? silver : r11 < 0.90 ? champagne : accent;
    float face = abs(flip);
    float light = 0.85 + 0.25 * clamp(u[5], 0.0, 1.0);          // the kick lifts the light a touch
    o.col = base * (0.22 + 0.78 * face) * light;
    o.glint = pow(face, 16.0) * (r11 < 0.72 ? 0.75 : 0.45) * light;
    float life = 10.0 + 4.5 * r6;
    o.alpha = smoothstep(0.0, 0.05, t) * (1.0 - smoothstep(life - 1.6, life, t)) * (nearCam ? 0.8 : 1.0);
    return o;
}

fragment float4 confettiFrag(CVOut in [[stage_in]]) {
    float2 q = abs(in.q);
    float a = in.alpha * (1.0 - smoothstep(0.62, 1.0, max(q.x, q.y)));   // soft edge: antialiasing at 5-15 px
    float3 c = in.col + float3(1.0, 0.94, 0.82) * in.glint;
    return float4(c * a, a);
}
"""#
