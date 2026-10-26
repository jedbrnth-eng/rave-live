// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

// SHOW mode transitions: blend scene A -> B over a beat-locked progress 0..1.
let transitionShaderSource = #"""
#include <metal_stdlib>
using namespace metal;
constexpr sampler ls(address::clamp_to_edge, filter::linear);
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut tvert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
}
float h11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
float h21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float vn(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + float2(1, 0)), f.x), mix(h21(i + float2(0, 1)), h21(i + float2(1, 1)), f.x), f.y);
}
float fbm(float2 p) { float a = 0.5, s = 0; for (int i = 0; i < 5; i++) { s += a * vn(p); p *= 2.02; a *= 0.5; } return s; }
float3 pal(float t) { return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67))); }
float2 rot(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }

// u: 0 progress, 1 type, 2 time, 3 aspect, 4 beat pulse, 5 hue, 6 flash amount (drop cut: 0.3 Chill, 0.55 Normal, 1 Wild)
fragment float4 tmix(VOut in [[stage_in]], texture2d<float> A [[texture(0)]], texture2d<float> B [[texture(1)]],
                     constant float *u [[buffer(0)]]) {
    float p = clamp(u[0], 0.0, 1.0); int type = int(u[1]); float t = u[2], aspect = u[3], hue = u[5], flash = u[6];
    float e = p * p * (3.0 - 2.0 * p);
    float2 uv = in.uv;
    float2 c = (uv - 0.5) * float2(aspect, 1.0);
    float3 col;
    if (type == 0) {                       // drop: one clean cut on the drop + a short white bloom that eases out
        float3 b = B.sample(ls, uv).rgb;
        float f = flash * pow(1.0 - p, 3.0);
        col = mix(b, float3(1.0), f * 0.6) + b * f * 0.5;
    } else if (type == 1) {                // iris: B opens from the centre with a glowing ring
        float r = e * 1.15 * max(aspect, 1.0);
        float d = length(c) - r;
        float m = smoothstep(0.008, -0.008, d);
        col = mix(A.sample(ls, uv).rgb, B.sample(ls, uv).rgb, m);
        col += pal(hue + atan2(c.y, c.x) * 0.16) * exp(-abs(d) * 45.0) * 1.4 * sin(3.14159 * p);
    } else if (type == 2) {                // liquid melt along a flowing noise front
        float n = fbm(c * 2.2 + float2(t * 0.15, -t * 0.1));
        float edge = e * 1.3 - 0.15;
        float g = exp(-abs(n - edge) * 25.0) * sin(3.14159 * p);
        float2 disp = float2(n - 0.5, 0.5 - n) * 0.06 * g;
        float m = 1.0 - smoothstep(edge - 0.02, edge + 0.02, n);
        col = mix(A.sample(ls, uv + disp).rgb, B.sample(ls, uv - disp).rgb, m);
        col += pal(hue + n * 2.0) * g * 0.9;
    } else if (type == 3) {                // zoom punch: A rushes past the camera, B lands
        float za = 1.0 + 2.5 * e, zb = 0.7 + 0.3 * e;
        float3 a = float3(0.0);
        for (int k = 0; k < 6; k++) {      // radial blur on the outgoing scene
            float zz = za * (1.0 + float(k) * 0.03 * e);
            a += A.sample(ls, (uv - 0.5) / zz + 0.5).rgb;
        }
        a /= 6.0;
        float3 b = B.sample(ls, (uv - 0.5) / zb + 0.5).rgb;
        col = mix(a, b, smoothstep(0.25, 0.85, p)) + float3(1.0) * exp(-abs(p - 0.5) * 14.0) * 0.12 * (0.5 + flash);
    } else if (type == 4) {                // glitch slices with RGB split
        float row = floor(uv.y * 28.0);
        float step = floor(p * 14.0);
        bool sw = h11(row * 3.7 + 1.3) < e + 0.15 * (h11(row + step) - 0.5);
        float sh = (h11(row * 9.1 + step) - 0.5) * 0.09 * sin(3.14159 * p);
        float2 o = float2(0.006 * sin(3.14159 * p), 0.0);
        if (sw) col = float3(B.sample(ls, uv + float2(sh, 0) + o).r, B.sample(ls, uv + float2(sh, 0)).g, B.sample(ls, uv + float2(sh, 0) - o).b);
        else    col = float3(A.sample(ls, uv + float2(sh, 0) + o).r, A.sample(ls, uv + float2(sh, 0)).g, A.sample(ls, uv + float2(sh, 0) - o).b);
    } else if (type == 5) {                // pixel dissolve: blocks grow, flip, shrink
        float sz = mix(1.0, 64.0, sin(3.14159 * p)) / 1080.0;
        float2 q = (floor(uv / float2(sz / aspect, sz)) + 0.5) * float2(sz / aspect, sz);
        float h = h21(floor(uv / float2(sz / aspect, sz)) + 0.37);
        col = h < e ? B.sample(ls, q).rgb : A.sample(ls, q).rgb;
    } else if (type == 7) {                // crossfade (Classic preset changes): soft dissolve, the outgoing scene drifts back a little
        float3 a = A.sample(ls, (uv - 0.5) / (1.0 + 0.04 * e) + 0.5).rgb;
        col = mix(a, B.sample(ls, uv).rgb, e);
    } else {                               // spin-kaleido: both scenes rotate through a mirror fold
        float fold = sin(3.14159 * p);
        float a = atan2(c.y, c.x), r = length(c);
        float seg = 3.14159 / 3.0;
        float af = abs(fmod(a + 10.0 * 3.14159, seg) - seg * 0.5);
        float2 kc = mix(c, r * float2(cos(af), sin(af)), fold);
        float2 ua = rot(kc, e * 1.6) / float2(aspect, 1.0) + 0.5;
        float2 ub = rot(kc, -(1.0 - e) * 1.6) / float2(aspect, 1.0) + 0.5;
        col = mix(A.sample(ls, ua).rgb, B.sample(ls, ub).rgb, e);
    }
    return float4(col, 1.0);
}
"""#
