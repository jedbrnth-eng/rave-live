// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

// Visuals-only mode: classic feedback visualizers (WMP Ambience/Battery, iTunes Classic, Winamp/MilkDrop, scope).
// Technique: each frame warps the previous frame (zoom/rotate/swirl + decay) and draws new audio shapes on top.
let visualsShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut vvert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
}

#define RES_X u[0]
#define RES_Y u[1]
#define TIME u[2]
#define ENERGY u[3]
#define BASS u[4]
#define MID u[5]
#define HIGH u[6]
#define KICK u[7]
#define BEAT u[8]
#define PHASE u[9]
#define BEATIDX u[10]
#define PRESET u[11]
#define DROP u[12]
#define STROBE u[13]
#define FADE u[14]
#define HUE u[15]
#define BLACKOUT u[16]
#define SNARE u[17]
#define VAR u[18]        // per-visit variation seed 0..1
#define PALIDX u[19]     // palette index 0..6
#define BCLK u[54]       // continuous beat clock in beats (grid-locked when tempo locked, 120 BPM free-run otherwise)
#define FRAMES u[20]     // frame-time scale (dt * 60): feedback motion is per-60Hz-frame, not per drawn frame

constant float PI = 3.14159265;
constexpr sampler fb(address::mirrored_repeat, filter::linear);

float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
// 7 cosine palettes (Inigo Quilez's palette formula); chosen per visit so the same preset never looks the same twice
float3 palx(float t, constant float *u) {
    int k = int(PALIDX) % 7;
    float3 a = float3(0.5), b = float3(0.5), c = float3(1.0), d = float3(0.0, 0.33, 0.67);
    if (k == 1) d = float3(0.0, 0.10, 0.20);
    else if (k == 2) d = float3(0.30, 0.20, 0.20);
    else if (k == 3) { c = float3(1.0, 1.0, 0.5); d = float3(0.80, 0.90, 0.30); }
    else if (k == 4) { c = float3(1.0, 0.7, 0.4); d = float3(0.0, 0.15, 0.20); }
    else if (k == 5) { c = float3(2.0, 1.0, 0.0); d = float3(0.50, 0.20, 0.25); }
    else if (k == 6) { a = float3(0.8, 0.5, 0.4); b = float3(0.2, 0.4, 0.2); c = float3(2.0, 1.0, 1.0); d = float3(0.0, 0.25, 0.25); }
    return a + b * cos(6.28318 * (c * t + d));
}
#define pal(t) palx((t), u)
float2 rot(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }
float3 hueShift(float3 c, float a) {
    const float3 k = float3(0.57735);
    float ca = cos(a);
    return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}
float waveAt(constant float *wave, float x) {           // x in 0..1, linear interpolation
    float f = clamp(x, 0.0, 1.0) * 510.0; int i = int(f); float t = f - float(i);
    return mix(wave[i], wave[i + 1], t);
}
float specAt(constant float *spec, float x) {
    float f = clamp(x, 0.0, 1.0) * 126.0; int i = int(f); float t = f - float(i);
    return mix(spec[i], spec[i + 1], t);
}
// distance from p to the polyline y = A * wave(x) across the screen (checks neighbours so steep parts stay solid)
float scopeDist(float2 p, constant float *wave, float aspect, float A, float y0) {
    float x = (p.x / aspect) * 0.5 + 0.5;
    float d = 1e5;
    for (int k = -3; k <= 3; k++) {
        float x0 = x + float(k) / 511.0, x1 = x0 + 1.0 / 511.0;
        float2 a = float2((x0 - 0.5) * 2.0 * aspect, y0 + A * waveAt(wave, x0));
        float2 b = float2((x1 - 0.5) * 2.0 * aspect, y0 + A * waveAt(wave, x1));
        float2 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        d = min(d, length(pa - ba * h));
    }
    return d;
}


// ---------- raymarched presets (no feedback): fractal cathedral, wormhole, liquid chrome
float3x3 rotY(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c)); }
float3x3 rotX(float a) { float c = cos(a), s = sin(a); return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c)); }
float kifs(float3 z, float scale, float3 off, thread float &trap) {
    float r = 1.0; trap = 1e5;
    for (int i = 0; i < 7; i++) {
        z = abs(z);
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;
        z = z * scale - off * (scale - 1.0);
        if (z.z < -0.5 * off.z * (scale - 1.0)) z.z += off.z * (scale - 1.0);
        r *= scale;
        trap = min(trap, length(z));
    }
    return (length(z) - 2.0) / r;
}
// Apollonian fractal (after Inigo Quilez's public formulation), flown through slowly; bass breathes the scale.
float apollo(float3 p, float s, thread float &orb) {
    float scale = 1.0; orb = 1e4;
    for (int i = 0; i < 8; i++) {
        p = -1.0 + 2.0 * fract(0.5 * p + 0.5);
        float r2 = dot(p, p);
        orb = min(orb, r2);
        float k = s / r2;
        p *= k; scale *= k;
    }
    return 0.25 * abs(p.y) / scale;
}
float3 fractalCathedral(float2 p, constant float *u) {
    float t = TIME, tb = BCLK;
    float3 ro = float3(0.8 + 0.25 * sin(t * 0.07), 0.55 + 0.1 * cos(t * 0.05), 0.4 + t * 0.03);
    float3 rd = normalize(float3(p, 1.4));
    rd = rotY(0.4 * sin(t * 0.05) + tb * 0.004) * rotX(0.25 + 0.15 * sin(t * 0.04)) * rd;
    float s = 1.18 + 0.06 * BASS + 0.04 * KICK;
    float d = 0.001, orb = 0.0, glow = 0.0; int i = 0; bool hit = false;
    for (i = 0; i < 90; i++) {
        float tr;
        float h = apollo(ro + rd * d, s, tr);
        glow += exp(-h * 300.0) * 0.006;
        if (h < 0.00025 * d) { orb = tr; hit = true; break; }
        d += h;
        if (d > 3.0) break;
    }
    float3 col = float3(0.0);
    if (hit) {
        float ao = 1.0 - float(i) / 90.0;
        float3 q = ro + rd * d;
        float2 e = float2(0.0004 * d + 0.00005, 0.0); float tq;
        float3 n = normalize(float3(apollo(q + e.xyy, s, tq) - apollo(q - e.xyy, s, tq),
                                    apollo(q + e.yxy, s, tq) - apollo(q - e.yxy, s, tq),
                                    apollo(q + e.yyx, s, tq) - apollo(q - e.yyx, s, tq)));
        float3 L = normalize(float3(0.5, 0.8, -0.3));
        float dif = clamp(dot(n, L), 0.0, 1.0);
        float spe = pow(clamp(dot(reflect(rd, n), L), 0.0, 1.0), 24.0);
        float3 base = pal(HUE + orb * 0.6 + d * 0.3);
        float rim = smoothstep(0.35, 0.0, orb) * (0.5 + 2.0 * BEAT);    // inner edges flash on the beat
        col = base * (0.25 + 1.3 * dif) * (0.35 + 0.65 * ao) * 1.5 + float3(1.0) * spe * 0.8 + pal(HUE + 0.5) * rim * ao * 1.2;
        col *= exp(-d * 0.45);
    }
    col += pal(HUE + 0.3) * glow * (0.6 + 1.5 * KICK + 2.0 * DROP);
    return col;
}
float3 wormhole(float2 p, constant float *u) {
    float t = TIME, tb = BCLK;
    float2 q = p + 0.15 * float2(sin(t * 0.3), cos(t * 0.23));
    float r = length(q), a = atan2(q.y, q.x);
    float z = 1.0 / max(r, 0.001);
    float tw = a + z * 0.15 * sin(t * 0.2) + t * 0.1;
    float travel = z + tb * 0.35;
    float ring = exp(-abs(fract(travel) - 0.5) * 18.0);
    float spokes = exp(-abs(fract(tw / (2.0 * PI) * 16.0) - 0.5) * 22.0);
    float pulse = exp(-abs(fract(travel * 0.25 - tb * 0.25 + 0.5) - 0.5) * 40.0) * (0.5 + KICK);
    float fog = exp(-z * 0.12);
    float3 c = pal(HUE + travel * 0.02 + cos(a) * 0.1) * (ring * 0.9 + spokes * 0.35) * fog;
    c += float3(1.0) * pulse * fog * 1.2;
    c += pal(HUE + 0.5) * exp(-r * 6.0) * (0.3 + BEAT);       // light at the end of the tunnel
    return c;
}
float smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }
float blobs(float3 q, constant float *u) {
    float t = TIME, tb = BCLK;
    float d = 1e5;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float3 c = float3(sin(t * 0.5 + fi * 1.7) * 1.1, cos(t * 0.43 + fi * 2.3) * 0.7, sin(t * 0.37 + fi) * 0.6);
        float rr = 0.42 + 0.18 * BASS + 0.12 * KICK * step(fmod(fi + floor(tb), 3.0), 0.5);
        d = smin(d, length(q - c) - rr, 0.55);
    }
    return d;
}
float3 liquidChrome(float2 p, constant float *u) {
    float3 ro = float3(0, 0, -4.0), rd = normalize(float3(p, 1.7));
    float d = 0.0; bool hit = false;
    for (int i = 0; i < 64; i++) {
        float h = blobs(ro + rd * d, u);
        if (h < 0.001) { hit = true; break; }
        d += h; if (d > 9.0) break;
    }
    // background: soft neon gradient + spectrum horizon
    float3 bg = pal(HUE + p.y * 0.2) * 0.06 + pal(HUE + 0.5) * exp(-abs(p.y + 0.35) * 12.0) * (0.15 + 0.5 * BEAT);
    if (!hit) return bg;
    float3 q = ro + rd * d;
    float2 e = float2(0.002, 0.0);
    float3 n = normalize(float3(blobs(q + e.xyy, u) - blobs(q - e.xyy, u), blobs(q + e.yxy, u) - blobs(q - e.yxy, u), blobs(q + e.yyx, u) - blobs(q - e.yyx, u)));
    float3 rf = reflect(rd, n);
    // fake studio environment: neon strips that sweep with the beat
    float strips = exp(-abs(fract(rf.y * 3.0 + BCLK * 0.25) - 0.5) * 14.0);
    float3 env = pal(HUE + rf.x * 0.3 + rf.y * 0.2) * (0.25 + 1.4 * strips) + float3(1.0) * pow(max(rf.y, 0.0), 12.0) * 2.0;
    float fres = pow(1.0 - max(dot(-rd, n), 0.0), 3.0);
    return env * (0.35 + 0.65 * fres) + float3(1.0) * pow(max(dot(rf, normalize(float3(0.4, 0.7, -0.5))), 0.0), 40.0) * (1.0 + KICK);
}


// ================= presets 11-22 =================
float2 hash22(float2 p) { float n = sin(dot(p, float2(41.0, 289.0))); return fract(float2(262144.0, 32768.0) * n); }
float vnoise2(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}
float fbm5(float2 p) { float a = 0.5, s = 0.0; for (int i = 0; i < 5; i++) { s += a * vnoise2(p); p = float2(p.x * 1.6 + p.y * 1.2, -p.x * 1.2 + p.y * 1.6); a *= 0.5; } return s; }

// 11 synthwave: striped sun, neon grid racing at the tempo
float3 synthwave(float2 p, constant float *u) {
    float t = TIME, tb = BCLK;
    float hz = -0.05;
    float3 col = mix(pal(0.75) * 0.08, pal(0.95) * 0.45, smoothstep(hz, 0.9, p.y));
    float2 sc = p - float2(0.0, 0.28);
    float sun = smoothstep(0.43 + 0.04 * KICK, 0.41 + 0.04 * KICK, length(sc));
    float cut = p.y < 0.28 ? step(0.35 + 0.3 * (0.28 - p.y) * 2.5, fract((0.28 - p.y) * 14.0 - t * 0.4)) : 1.0;
    col += mix(float3(1.0, 0.85, 0.25), float3(1.0, 0.15, 0.55), smoothstep(0.7, -0.05, p.y)) * sun * cut * (1.0 + 0.6 * BEAT);
    col += pal(0.9) * exp(-length(sc) * 3.0) * 0.25;
    if (p.y < hz) {
        float z = 0.35 / (hz - p.y + 0.0005);
        float x = p.x * z * 0.5;
        float zz = z * 0.5 + tb * 0.5;
        float dx = 0.5 - abs(fract(x) - 0.5), dz = 0.5 - abs(fract(zz) - 0.5);
        float w = 0.02 * z;
        float g = exp(-dx / w) + exp(-dz / w) * (1.0 + 2.0 * BEAT * step(fract(zz * 0.25), 0.25));
        col = pal(0.8 + 0.1 * sin(zz * 0.3)) * 0.04 + pal(0.85) * g * exp(-z * 0.06) * 1.2;
    }
    col += pal(0.9) * exp(-abs(p.y - hz) * 60.0) * (0.6 + BASS);
    col *= 0.85 + 0.35 * BEAT;                                       // whole stage breathes on the beat
    return col;
}

// 12 voronoi crystals: cells glow with the spectrum, cracks flash on kicks
float3 crystals(float2 p, constant float *u, constant float *spec) {
    float t = TIME;
    float2 q = rot(p, t * 0.03 + VAR * 6.0) * (3.0 + 2.0 * VAR);
    float2 c = floor(q), f = fract(q);
    float d1 = 8.0, d2 = 8.0; float2 id = float2(0.0);
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        float2 g = float2(i, j);
        float2 o = hash22(c + g);
        o = 0.5 + 0.45 * sin(t * 0.6 + 6.2831 * o);
        float d = length(g + o - f);
        if (d < d1) { d2 = d1; d1 = d; id = c + g; } else if (d < d2) d2 = d;
    }
    float h = hash21(id);
    float s = specAt(spec, h);
    float3 col = pal(h + HUE) * (0.08 + 0.9 * s * s) * (0.7 + 0.6 * KICK) * smoothstep(1.0, 0.0, d1);
    col += pal(h + 0.5) * exp(-(d2 - d1) * (30.0 - 15.0 * KICK)) * (0.3 + 1.2 * KICK + BEAT * 0.4);
    return col;
}

// 13 truchet maze: neon arcs with light pulses running at the tempo
float3 truchet(float2 p, constant float *u) {
    float t = TIME, tb = BCLK;
    float z = 4.0 + 2.0 * VAR + 0.5 * sin(t * 0.1);
    float2 q = rot(p, t * 0.02) * z + float2(t * 0.15, tb * 0.1);
    float2 c = floor(q), f = fract(q) - 0.5;
    if (hash21(c) > 0.5) f.x = -f.x;
    float2 a = f - float2(0.5, 0.5) * sign(f.x + f.y + 0.0001);
    float d = abs(length(a) - 0.5);
    float ang = atan2(a.y, a.x);
    float run = fract(ang * 0.6366 + tb * 0.5 + hash21(c + 3.0));
    float pulse = exp(-run * 6.0) * (0.5 + KICK);
    float3 col = pal(hash21(c) * 0.3 + HUE + t * 0.02) * exp(-d * 28.0) * 0.55;
    col += float3(1.0) * exp(-d * 60.0) * pulse;
    return col * (0.7 + 0.5 * BEAT);
}

// 14 spectrum waterfall (Unknown-Pleasures ridges, uses feedback scroll)
float3 waterfallLine(float2 p, constant float *u, constant float *spec, float aspect) {
    float x = (p.x / aspect) * 0.5 + 0.5;
    float m = exp(-pow((x - 0.5) * 3.2, 2.0));
    float y0 = -0.75 + 0.55 * m * specAt(spec, abs(x - 0.5) * 2.0);
    float d = abs(p.y - y0);
    float3 col = pal(HUE + x * 0.3) * exp(-d * 260.0) * 1.4 * (0.65 + 0.9 * BEAT);
    col *= step(abs(x - 0.5), 0.42);
    return col;
}

// 15 galaxy: logarithmic spiral arms, stars, kick-lit core
float3 galaxy(float2 p, constant float *u) {
    float t = TIME;
    float2 q = rot(p, -t * 0.08);
    float r = length(q), a = atan2(q.y, q.x);
    float arms = 2.0 + floor(VAR * 3.0);
    float sp = sin(a * arms - log(r + 0.001) * 5.0 + t * 0.4);
    float n = fbm5(q * 4.0 + t * 0.05);
    float dust = smoothstep(0.2, 1.0, sp * 0.5 + 0.5) * exp(-r * 1.6) * (0.4 + 0.8 * n);
    float3 col = pal(HUE + r * 0.4) * dust * (0.6 + 0.8 * BASS) * (0.8 + 0.5 * KICK);
    float2 g = q * 90.0;
    float st = step(0.985, hash21(floor(g))) * exp(-length(fract(g) - 0.5) * 9.0) * (0.3 + dust * 4.0);
    col += float3(1.0) * st;
    col += pal(HUE + 0.1) * exp(-r * 9.0) * (0.6 + 1.6 * KICK);
    return col;
}

// 16 mandala: k-fold petals breathing with the beat
float3 mandala(float2 p, constant float *u, constant float *spec) {
    float t = TIME, tb = BCLK;
    float k = 6.0 + 2.0 * floor(VAR * 4.0);
    float r = length(p), a = atan2(p.y, p.x) + t * 0.05;
    float seg = 6.28318 / k;
    float af = abs(fmod(a + 100.0 * 6.28318, seg) - seg * 0.5);
    float2 q = r * float2(cos(af), sin(af));
    float petals = sin(q.y * 18.0 + sin(q.x * 9.0 - tb * 0.5) * 2.0) * cos(r * 14.0 - tb * 1.0);
    float rings = exp(-abs(fract(r * 4.0 - tb * 0.25) - 0.5) * 14.0);
    float v = smoothstep(0.3, 1.0, petals) * 0.9 + rings * 0.4;
    float s = specAt(spec, fract(r * 0.9));
    float3 col = pal(HUE + r * 0.6 + af) * v * (0.6 + 1.6 * s) * (0.75 + 0.5 * KICK) * smoothstep(1.6, 0.1, r);
    col += pal(HUE + 0.5) * exp(-r * 10.0) * (0.5 + KICK);
    return col;
}

// 17 lissajous laser (feedback trails)
float3 lissajous(float2 p, constant float *u, constant float *wave, float aspect) {
    float t = TIME;
    float A = 2.0 + floor(VAR * 3.0), B = A + 1.0 + floor(fract(VAR * 7.0) * 2.0);
    float d = 1e5;
    float2 prev = float2(0.0);
    for (int i = 0; i <= 56; i++) {
        float s = float(i) / 56.0 * 6.28318;
        float w = waveAt(wave, float(i) / 56.0);
        float2 c = float2(sin(A * s + t * 0.7) * 0.85 * aspect * 0.55, sin(B * s + t * 0.31) * 0.75) * (1.0 + 0.25 * w + 0.1 * KICK);
        if (i > 0) {
            float2 pa = p - prev, ba = c - prev; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            d = min(d, length(pa - ba * h));
        }
        prev = c;
    }
    return pal(HUE + t * 0.05) * (0.65 + 0.7 * BEAT) * (exp(-d * 220.0) * 1.3 + exp(-d * 25.0) * 0.12);
}

// 18 audio sphere: a planet whose surface is the spectrum
float sphereDE(float3 q, constant float *u, constant float *spec) {
    float r = length(q);
    float lat = acos(clamp(q.y / max(r, 1e-4), -1.0, 1.0)) / 3.14159;
    float lon = atan2(q.z, q.x);
    float lx = abs(lat - 0.5) * 2.0;
    float s = 0.25 * (specAt(spec, lx - 0.04) + 2.0 * specAt(spec, lx) + specAt(spec, lx + 0.04));      // smoothed across bins: no terraced slabs
    float bump = s * 0.35 * (0.6 + 0.4 * sin(lon * 6.0 + TIME)) + 0.08 * KICK;
    return r - (0.9 + bump);
}
float3 audioSphere(float2 p, constant float *u, constant float *spec) {
    float t = TIME;
    float3 ro = float3(0.0, 0.0, -2.1), rd = normalize(float3(p, 1.3));      // closer camera: the planet fills more of the frame
    float3x3 R = rotY(t * 0.25) * rotX(0.3 + 0.2 * sin(t * 0.17));
    ro = R * ro; rd = R * rd;
    float d = 0.0; bool hit = false; float glow = 0.0;
    for (int i = 0; i < 44; i++) {
        float h = sphereDE(ro + rd * d, u, spec);
        glow += exp(-max(h, 0.0) * 10.0) * 0.025;
        if (h < 0.003) { hit = true; break; }
        d += h * 0.8; if (d > 5.0) break;
    }
    float3 col = pal(HUE + 0.6) * glow * (0.5 + BEAT);
    if (hit) {
        float3 q = ro + rd * d; float2 e = float2(0.003, 0.0);
        float3 n = normalize(float3(sphereDE(q + e.xyy, u, spec) - sphereDE(q - e.xyy, u, spec), sphereDE(q + e.yxy, u, spec) - sphereDE(q - e.yxy, u, spec), sphereDE(q + e.yyx, u, spec) - sphereDE(q - e.yyx, u, spec)));
        float fres = pow(1.0 - max(dot(-rd, n), 0.0), 2.5);
        float bands = exp(-abs(fract(length(q) * 10.0 - TIME) - 0.5) * 10.0);
        col += pal(HUE + length(q) * 1.5) * (0.15 + 0.6 * max(dot(n, normalize(float3(0.5, 0.8, -0.6))), 0.0)) + pal(HUE + 0.5) * fres * 1.4 + float3(1.0) * bands * 0.15;
    }
    return col;
}

// 19 northern lights: layered curtains over a dark horizon, swaying with the bass
float3 northernLights(float2 p, constant float *u) {
    float t = TIME;
    float3 col = float3(0.0);
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float x = p.x * (0.6 + fi * 0.15) + fi * 3.1;
        float wave = fbm5(float2(x * 0.8 + t * 0.06 * (1.0 + fi * 0.2), fi + t * 0.03)) * 0.9;
        float base = -0.15 + fi * 0.09 + wave * 0.35 + 0.08 * BASS * sin(x * 2.0 + t);
        float h = p.y - base;
        float curtain = (h > 0.0 ? exp(-h * (2.2 + fi * 0.4)) : exp(h * 45.0));
        float rays = 0.55 + 0.45 * vnoise2(float2(x * 30.0, t * 0.6 + fi));
        col += pal(HUE + fi * 0.06 + h * 0.4) * curtain * rays * (0.18 + 0.22 * MID) * (1.0 + 0.6 * BEAT);
    }
    float stars = step(0.996, hash21(floor(p * 220.0))) * smoothstep(-0.1, 0.6, p.y);
    col += float3(stars) * 0.8;
    col *= smoothstep(-0.55, -0.4, p.y);
    col += pal(HUE + 0.5) * 0.04 * smoothstep(-0.4, -0.6, p.y);   // lake reflection glow
    return col;
}

// 20 ink nebula: domain-warped fbm, bass pushes the warp
float3 nebula(float2 p, constant float *u) {
    float t = TIME * 0.12;
    float2 q = p * (1.2 + VAR);
    float2 w1 = float2(fbm5(q + float2(0.0, t)), fbm5(q + float2(5.2, 1.3) - t));
    float2 w2 = float2(fbm5(q + 3.0 * w1 + float2(1.7, 9.2) + t * 1.5), fbm5(q + 3.0 * w1 + float2(8.3, 2.8)));
    float f = fbm5(q + (3.0 + 2.0 * BASS) * w2);
    float3 col = pal(HUE + f * 0.8 + length(w2) * 0.3) * pow(f, 2.2) * (1.6 + 1.2 * BEAT);
    col += pal(HUE + 0.5) * pow(length(w1), 4.0) * 0.5 * (0.5 + KICK);
    return col;
}

// 21 glyph rain
float3 glyphRain(float2 p, constant float *u, float aspect) {
    float t = TIME, tb = BCLK;
    float2 uv = float2(p.x / aspect * 0.5 + 0.5, 0.5 - p.y * 0.5);
    float cols = 64.0;
    float cx = floor(uv.x * cols);
    float rows = cols / aspect * 1.1;
    float cy = floor(uv.y * rows);
    float speed = 0.35 + 0.65 * hash21(float2(cx, 1.0));
    float head = fract(hash21(float2(cx, 7.0)) + tb * 0.125 * speed);
    float pos = uv.y - head;
    float trail = pos < 0.0 ? exp(pos * 7.0) : 0.0;
    float2 f = fract(float2(uv.x * cols, uv.y * rows));
    float2 g = floor(f * 5.0);
    float glyph = step(0.5, hash21(g + float2(cx, cy) * 7.0 + floor(t * 6.0 * hash21(float2(cy, cx))))) * step(0.1, f.x) * step(f.x, 0.9);
    float3 c = mix(pal(HUE + 0.3), float3(1.0), smoothstep(-0.02, 0.0, pos) * step(pos, 0.0));
    return c * glyph * trail * (0.7 + 0.6 * BEAT + KICK * 0.4);
}

// 22 hyperdrive: sparse layered 3D starfield, slow cruise (Jed: the dense/fast version was overwhelming)
float3 hyperdrive(float2 p, constant float *u) {
    float tb = BCLK;
    float3 col = float3(0.0);
    float speed = 0.07 + 0.08 * ENERGY + 0.18 * DROP;   // slow cruise; drops nudge it, never lightspeed
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float z = fract(fi / 8.0 + tb * 0.12 * speed);
        float scale = mix(14.0, 0.8, z);
        float fade = smoothstep(0.0, 0.35, z) * smoothstep(1.0, 0.8, z);
        float2 q = p * scale + fi * 17.3;
        float2 c = floor(q), f = fract(q) - 0.5;
        float keep = step(0.45, hash21(c + 5.1));          // only ~55% of cells hold a star: room to breathe
        float2 o = (hash22(c) - 0.5) * 0.3;                // stay near the cell centre so glows aren't clipped into squares
        float2 dv = f - o;
        float2 dir = normalize(p + 1e-4);
        float along = dot(dv, dir), across = dot(dv, float2(-dir.y, dir.x));
        float streak = (0.02 + 0.25 * speed) * z;
        float d = length(float2(across, along / (1.0 + streak * 30.0)));
        float edge = smoothstep(0.5, 0.36, max(abs(f.x), abs(f.y)));   // soft-fade glows at cell borders: no hard square seams
        col += pal(HUE + 0.5 * hash21(c)) * exp(-d * 32.0) * fade * keep * edge * (0.9 + 0.3 * KICK);
    }
    col += pal(HUE + 0.5) * exp(-length(p) * 4.0) * 0.25 * (0.6 + 0.4 * BEAT);
    return col;
}


// ================= presets 23-31 (visuals pack 1) =================
// Pointer slots (filled by VisualsRenderer.encode): NPTR, ptr* (mouse / camera hands), click* (ring of last 4 clicks / pinches).
// Techniques are standard Shadertoy-era ideas re-implemented here from scratch (see CREDITS.md): curl-noise advection, Gray-Scott
// reaction-diffusion (Pearson 1993 parameters), 2D wave equation, Vogel/phyllotaxis spiral (golden angle), ridged heightfields,
// box-grid city marching with cell-exit bound, radial firework shells.
#define NPTR int(u[21])
float2 ptrPos(constant float *u, int i) { return float2(u[22 + 5 * i], u[23 + 5 * i]); }
float2 ptrVel(constant float *u, int i) { return float2(u[24 + 5 * i], u[25 + 5 * i]); }
float ptrStr(constant float *u, int i) { return i < NPTR ? u[26 + 5 * i] : 0.0; }
float3 clickAt(constant float *u, int i) { return float3(u[37 + 3 * i], u[38 + 3 * i], u[39 + 3 * i]); }   // x, y, age (s); age 99 = none
// "pull" of the strongest pointer toward a steering offset in -1..1 (0 when nobody is touching)
float2 steer(constant float *u, float aspect) {
    float2 s = float2(0.0);
    for (int i = 0; i < 3; i++) { float k = clamp(ptrStr(u, i) * 2.0 - 0.3, 0.0, 1.0); s += float2(ptrPos(u, i).x / aspect, ptrPos(u, i).y) * k; }
    return clamp(s, -1.0, 1.0);
}

// ---- 23 ink in water: curl-noise flow advects the feedback frame; kicks drop ink, pointers paint and stir it
float inkPot(float2 x, float t) { return sin(x.x * 1.7 + 1.3 * sin(x.y * 1.1 + t * 3.0)) * cos(x.y * 1.5 - 1.1 * sin(x.x * 0.9 - t * 2.3)) + 0.5 * sin(x.x * 3.1 + x.y * 2.3 + t * 5.0) * cos(x.y * 2.7 - x.x * 1.9 - t * 4.0); }
float2 inkDisp(float2 p, constant float *u) {
    float t = TIME * 0.07, e = 0.03; float2 q = p * 1.1;
    float2 fl = float2(inkPot(q + float2(0, e), t) - inkPot(q - float2(0, e), t), -(inkPot(q + float2(e, 0), t) - inkPot(q - float2(e, 0), t))) / (2.0 * e);
    float2 disp = fl * 0.0024 * (1.0 + 1.0 * BASS);
    for (int i = 0; i < 3; i++) {
        float s = ptrStr(u, i); if (s <= 0.0) continue;
        float2 d = p - ptrPos(u, i); float w = exp(-dot(d, d) * 14.0) * s;
        disp += -ptrVel(u, i) * (1.0 / 60.0) * 1.1 * w + float2(-d.y, d.x) * w * 0.006;
    }
    for (int i = 0; i < 4; i++) {
        float3 c = clickAt(u, i); if (c.z > 2.0) continue;
        float2 d = p - c.xy; float r = length(d) + 1e-4;
        float ring = exp(-pow((r - c.z * 0.7) * 5.0, 2.0)) * exp(-c.z * 1.4);
        disp -= (d / r) * ring * 0.012;
    }
    return disp;
}
float3 inkWater(float2 p, constant float *u, float aspect) {
    float t = TIME, tb = BCLK; float3 nw = float3(0.0);
    float fr = clamp(FRAMES, 0.25, 4.0);
    for (int i = 0; i < 4; i++) {      // four wandering ink wells
        float fi = float(i);
        float2 c = float2(sin(t * 0.11 + fi * 1.9) * 0.8 * aspect, cos(t * 0.09 + fi * 1.5) * 0.6);
        float2 d = p - c;
        nw += pal(HUE + fi * 0.33 + t * 0.01) * exp(-dot(d, d) * 380.0) * (0.10 + 0.10 * BASS) * fr;
    }
    // one bigger drop per beat, somewhere new
    float bi = floor(tb); float2 dp = (hash22(float2(bi, 3.7)) - 0.5) * float2(1.5 * aspect, 1.3);
    float2 dd = p - dp;
    nw += pal(HUE + hash21(float2(bi, 1.3)) * 0.8) * exp(-dot(dd, dd) * 110.0) * exp(-fract(BCLK) * 6.0) * (0.5 + 1.1 * KICK) * fr * 0.55;
    for (int i = 0; i < 3; i++) {      // pointers paint ink
        float s = ptrStr(u, i); if (s <= 0.0) continue;
        float2 d = p - ptrPos(u, i);
        nw += pal(HUE + t * 0.04 + float(i) * 0.35) * exp(-dot(d, d) * 1100.0) * s * 0.16 * fr;
    }
    for (int i = 0; i < 4; i++) {      // clicks drop a big blot
        float3 c = clickAt(u, i); if (c.z > 0.25) continue;
        float2 d = p - c.xy;
        nw += pal(HUE + hash21(c.xy * 31.0) + 0.2) * exp(-dot(d, d) * 90.0) * (1.0 - c.z / 0.25) * 0.5 * fr;
    }
    return nw;
}

// ---- 24 neon city: fly down a road between box towers (grid march with cell-exit bound)
float cityHeight(float2 id) { float h = hash21(id); return 0.7 + 3.4 * h * h + (hash21(id + 9.1) > 0.93 ? 2.6 : 0.0); }
float sdBox3(float3 p, float3 b) { float3 q = abs(p) - b; return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0); }
float cityDE(float3 p, float3 rd, float bass) {
    const float CS = 1.6;
    float2 id = float2(floor((p.x + 0.8) / CS), floor(p.z / CS));
    float d = p.y;
    if (id.x != 0.0) {
        float2 q = float2(p.x - id.x * CS, p.z - (id.y + 0.5) * CS);
        float hs = 0.42 + 0.2 * hash21(id + 3.3), h = cityHeight(id) * (1.0 + 0.05 * bass);
        d = min(d, sdBox3(float3(q.x, p.y - h * 0.5, q.y), float3(hs, h * 0.5, hs)));
    }
    float tx = rd.x > 1e-4 ? (id.x * CS + 0.8 - p.x) / rd.x : (rd.x < -1e-4 ? (id.x * CS - 0.8 - p.x) / rd.x : 1e5);
    float tz = rd.z > 1e-4 ? ((id.y + 1.0) * CS - p.z) / rd.z : (rd.z < -1e-4 ? (id.y * CS - p.z) / rd.z : 1e5);
    return min(d, min(tx, tz) + 0.02);
}
float3 neonCity(float2 p, constant float *u, constant float *spec, float aspect) {
    float t = TIME, tb = BCLK;
    float2 st = steer(u, aspect);
    float yaw = 0.18 * sin(t * 0.11) + st.x * 0.55, pitch = -0.06 + 0.04 * sin(t * 0.17) - st.y * 0.3;
    float3 ro = float3(0.28 * sin(t * 0.13) + st.x * 0.2, 1.2 + 0.18 * sin(t * 0.21), t * 0.8 + 0.02 * tb);
    float3 rd = normalize(float3(p, 1.5));
    rd = rotY(yaw) * rotX(pitch) * rd;
    float d = 0.02; bool hit = false;
    for (int i = 0; i < 72; i++) {
        float h = cityDE(ro + rd * d, rd, BASS);
        if (h < 0.0015 * d) { hit = true; break; }
        d += max(h, 0.004);
        if (d > 26.0 || (rd.y > 0.0 && ro.y + rd.y * d > 9.0)) break;
    }
    float3 fogc = pal(HUE + 0.25) * (0.16 + 0.06 * BEAT) + float3(0.02, 0.0, 0.05);
    float3 col = fogc * (0.5 + 1.5 * exp(-abs(rd.y) * 6.0));
    col += float3(step(0.997, hash21(floor(rd.xy * 300.0 + 7.0)))) * 0.5 * smoothstep(0.1, 0.4, rd.y);
    if (hit) {
        float3 q = ro + rd * d;
        float3 c = float3(0.0);
        if (q.y < 0.01) {                        // wet road: neon edge lines, dashed centre, passing light trails
            c = float3(0.012, 0.012, 0.03);
            c += pal(HUE + 0.1) * exp(-abs(abs(q.x) - 0.72) * 70.0) * 0.8;
            c += float3(1.0, 0.9, 0.7) * exp(-abs(q.x) * 160.0) * step(0.5, fract(q.z * 1.2)) * 0.4;
            for (int l = 0; l < 4; l++) {
                float lane = (l < 2 ? -1.0 : 1.0) * (0.22 + 0.2 * float(l % 2));
                float k = fract(q.z * 0.28 + hash21(float2(float(l), 4.0)) * 5.0 + (lane < 0.0 ? -1.0 : 1.0) * t * 0.05);
                c += (lane < 0.0 ? float3(1.0, 0.1, 0.12) : float3(0.9, 0.95, 1.0)) * exp(-abs(q.x - lane) * 190.0) * smoothstep(0.88, 1.0, k) * 1.4;
            }
        } else {
            float2 id = float2(floor((q.x + 0.8) / 1.6), floor(q.z / 1.6));
            float2 lq = float2(q.x - id.x * 1.6, q.z - (id.y + 0.5) * 1.6);
            float hs = 0.42 + 0.2 * hash21(id + 3.3), hh = cityHeight(id) * (1.0 + 0.05 * BASS);
            float bid = hash21(id);
            float3 loc = float3(lq.x, q.y - hh * 0.5, lq.y) / float3(hs, hh * 0.5, hs);
            float3 al = abs(loc);
            float3 neon = pal(HUE + (id.x < 0.0 ? 0.0 : 0.5));
            if (al.y > al.x && al.y > al.z) {    // roof
                c = float3(0.01, 0.008, 0.02) + neon * 0.05;
            } else {
                bool onX = al.x > al.z;           // wall faces +-x or +-z
                float wc = onX ? q.z : q.x;
                float2 uvw = float2(wc * 6.0, q.y * 5.0), cell = floor(uvw), f = fract(uvw);
                float win = step(0.15, f.x) * step(f.x, 0.85) * step(0.2, f.y) * step(f.y, 0.8);
                float hsh = hash21(cell + bid * 91.0 + (onX ? 0.0 : 40.0));
                float on = step(0.5, hash21(cell + 13.0 + floor(t * 0.15 + hsh * 6.0) * 3.0 + bid * 91.0));
                float lvl = (0.35 + 1.4 * specAt(spec, hsh)) * (1.0 + 0.5 * BEAT * step(0.6, hsh));
                c = float3(0.012, 0.01, 0.025) + pal(HUE + bid * 0.4 + hsh * 0.3) * win * on * lvl * 0.9;
                float ex = hs - abs(onX ? lq.y : lq.x);          // distance to the vertical edge
                c += neon * exp(-ex * 38.0) * 0.55 + neon * exp(-(hh - q.y) * 45.0) * 0.9;
            }
        }
        float fog = 1.0 - exp(-d * 0.085);
        col = mix(c, fogc * 1.2, fog);
    }
    return col;
}

// ---- 25 laser grid tunnel: rectangular corridor, lattice of laser lines + travelling rings; the vanishing point follows the pointer
float3 laserGrid(float2 p, constant float *u, float aspect) {
    float t = TIME, tb = BCLK;
    float2 st = steer(u, aspect);
    float2 c = float2(0.16 * sin(t * 0.19), 0.1 * cos(t * 0.15)) + st * float2(0.55 * aspect, 0.5) * 0.8;
    float2 q = p - c;
    float d = max(abs(q.x) / aspect, abs(q.y)) + 1e-3;
    float z = 1.0 / d;
    float zt = z * 0.35 + tb * 0.25;
    float ring = exp(-(0.5 - abs(fract(zt) - 0.5)) * 34.0);
    bool side = abs(q.x) / aspect > abs(q.y);
    float uu = side ? q.y / (abs(q.x) / aspect) : (q.x / aspect) / abs(q.y);     // -1..1 along the wall
    float wallId = side ? (q.x > 0.0 ? 0.0 : 1.0) : (q.y > 0.0 ? 2.0 : 3.0);
    float lg = abs(fract(uu * 3.0 + 0.5) - 0.5) / 3.0;
    float line = exp(-lg / (0.004 + 0.02 * d));
    float3 col = pal(HUE + wallId * 0.18) * line * 0.9 * smoothstep(0.02, 0.3, d);
    col += pal(HUE + 0.5) * ring * (0.35 + 0.5 * BEAT) * smoothstep(0.02, 0.25, d) * (0.5 + 0.5 * exp(-lg * 6.0));
    // slow searchlight fans
    float ang = atan2(q.y, q.x);
    col += pal(HUE + 0.3) * pow(abs(sin(ang * 5.0 + t * 0.12)), 50.0) * smoothstep(0.1, 0.9, d) * 0.5;
    col += pal(HUE + 0.3) * exp(-length(q) * 3.2) * (0.6 + 0.5 * BEAT + 0.5 * DROP);
    col *= 1.0 + 0.4 * DROP;
    for (int i = 0; i < 4; i++) {    // clicks send a bright frame rushing outward
        float3 ck = clickAt(u, i); if (ck.z > 2.5) continue;
        float band = exp(-pow((d - 0.05 - ck.z * 0.55) * 9.0, 2.0)) * exp(-ck.z * 0.9);
        col += pal(HUE + 0.1 + float(i) * 0.2) * band * (0.6 + 0.4 * (side ? exp(-lg * 8.0) : exp(-lg * 8.0))) * 1.2;
    }
    return col;
}

// ---- 26 terrain: a neon contour heightfield valley flown at cruise; a ridge of light rolls over the hills each beat
float terrBase(float2 x) {
    float h = 0.0, a = 0.5; float2 q = x;
    for (int i = 0; i < 3; i++) {
        float r = sin(q.x + sin(q.y * 0.7 + float(i) * 1.3)) * cos(q.y * 0.9 - sin(q.x * 0.6 + float(i) * 2.1));
        h += a * (1.0 - abs(r));
        q = float2(q.x * 1.7 + q.y * 0.9 + 3.1, -q.x * 0.9 + q.y * 1.7 - 1.7); a *= 0.5;
    }
    return h;
}
float terrH(float2 x, constant float *u, float camz) {
    float vc = 0.8 * sin(x.y * 0.12);
    float valley = smoothstep(0.3, 2.4, abs(x.x - vc));
    float H = valley * (terrBase(x * 0.55) - 0.3) * 2.2 * (1.0 + 0.35 * BASS + 0.5 * DROP) + 0.05 * sin(x.x * 2.0 + x.y * 1.3);
    float front = camz + 1.2 + 9.0 * fract(BCLK);                       // ridge of light travelling away on every beat
    H += valley * 0.28 * (0.2 + KICK) * exp(-pow((x.y - front) * 0.8, 2.0));
    return H;
}
float3 terrain(float2 p, constant float *u, float aspect) {
    float t = TIME;
    float cz = t * 0.7;
    float2 st = steer(u, aspect);
    float3 ro = float3(0.8 * sin(cz * 0.12), 1.05 + 0.1 * sin(t * 0.2), cz);
    float yaw = 0.2 * cos(cz * 0.12) * 0.8 + st.x * 0.5, pitch = -0.17 - st.y * 0.25;
    float3 rd = normalize(float3(p, 1.4));
    rd = rotY(yaw) * rotX(pitch) * rd;
    float d = 0.05; bool hit = false;
    for (int i = 0; i < 44; i++) {
        float3 q = ro + rd * d;
        float h = q.y - terrH(q.xz, u, cz);
        if (h < 0.003 * d) { hit = true; break; }
        d += max(h * 0.65, 0.025 * d);
        if (d > 17.0) break;
    }
    float3 hor = pal(HUE + 0.3);
    float3 sky = hor * 0.5 * exp(-max(rd.y, 0.0) * 5.0) + float3(0.0, 0.0, 0.03);
    float2 md = rd.xy - float2(0.0, 0.1) - float2(0.0, 0.0);
    float ml = length(md), MR = 0.16;
    if (ml < MR * 1.03) {                                  // cratered moon: lit sphere, dark maria, crater floors and bright rims
        float2 mq = md / MR; float zz = sqrt(max(1.0 - dot(mq, mq), 0.0));
        float lam = clamp(dot(float3(mq, zz), normalize(float3(-0.55, 0.5, 0.65))), 0.0, 1.0);
        float maria = smoothstep(0.38, 0.62, fbm5(mq * 1.7 + 4.0 + VAR * 7.0));
        float cfl = 0.0, rim = 0.0;
        for (int sc = 0; sc < 2; sc++) {                    // two crater scales: a few big basins plus small pocks
        float2 cq = mq * (sc == 0 ? 2.6 : 5.5) + float(sc) * 7.3, ci = floor(cq), cf = fract(cq);
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            float2 g = float2(i, j), id = ci + g + float(sc) * 31.0; float2 o = 0.2 + 0.6 * hash22(id); float r0 = 0.1 + 0.2 * hash21(id + 5.0);
            float dd = length(g + o - cf), on = step(0.4, hash21(id + 2.0));
            cfl += smoothstep(r0, r0 * 0.75, dd) * on;
            rim += exp(-abs(dd - r0) * 30.0) * on * (0.6 + 0.5 * clamp(dot(normalize(g + o - cf + 1e-4), float2(0.6, -0.8)), 0.0, 1.0));   // rim catches the light on its sun-facing side
        }
        }
        float alb = mix(0.95, 0.45, maria) * (1.0 - 0.4 * clamp(cfl, 0.0, 1.0)) + 0.3 * clamp(rim, 0.0, 1.0);
        float3 mc = mix(float3(1.0, 0.94, 0.88), hor, 0.15) * alb * (0.1 + 1.0 * lam) + hor * 0.05;
        sky = mix(sky, mc * 1.1, smoothstep(1.03, 0.97, ml / MR));
    }
    sky += hor * exp(-length(md) * 4.5) * 0.45;
    sky += float3(step(0.996, hash21(floor(rd.xy * 280.0)))) * 0.6 * smoothstep(0.15, 0.5, rd.y);
    if (!hit) return sky;
    float3 q = ro + rd * d;
    float gx = abs(fract(q.x * 1.0 + 0.5) - 0.5), gz = abs(fract(q.z * 1.0 + 0.5) - 0.5);
    float wd = 0.012 + 0.006 * d;
    float grid = exp(-min(gx, gz) / wd);
    float cont = exp(-abs(fract(q.y * 4.5 + 0.5) - 0.5) * (30.0 / (1.0 + 0.22 * d)));
    float3 c = float3(0.01, 0.005, 0.03) + pal(HUE + q.y * 0.35 + q.x * 0.03) * (grid * 0.95 + cont * 0.75);
    c += pal(HUE + 0.5) * exp(-pow((q.z - (cz + 1.2 + 9.0 * fract(BCLK))) * 0.8, 2.0)) * 0.25 * (0.3 + KICK) * (grid + cont);
    float fog = (1.0 - exp(-d * 0.16)) * (1.0 - 0.4 * DROP);      // drops thin the haze so ridges keep their layers
    return mix(c, sky * 0.9 + hor * 0.08, fog) * (1.0 + 0.35 * DROP);
}

// ---- 27 portal: ring gateway with an inward-spiralling particle river; follows the pointer, pinch/click sends a shockwave
float3 portal(float2 p, constant float *u, float aspect) {
    float t = TIME, tb = BCLK;
    float2 st = steer(u, aspect);
    float2 c = float2(0.1 * sin(t * 0.17), 0.07 * cos(t * 0.23)) + st * float2(0.7 * aspect, 0.6) * 0.8;
    float2 q = p - c; float r = length(q) + 1e-4, a = atan2(q.y, q.x);
    float R = 0.46 + 0.025 * BASS + 0.03 * KICK + 0.04 * DROP;
    float3 col = float3(0.0);
    col += pal(HUE + 0.1) * exp(-abs(r - R) * 38.0) * 0.9 + float3(1.0, 0.95, 0.85) * exp(-abs(r - R) * 150.0) * 0.8;
    col += pal(HUE + 0.2) * exp(-max(r - R, 0.0) * 4.0) * 0.10 * step(R, r);
    if (r < R) {                                          // inner vortex
        float s = sin(a * 3.0 + log(r + 0.02) * 6.0 - t * 0.7);
        float arms = smoothstep(0.1, 1.0, s) * pow(r / R, 0.6);
        col += pal(HUE + 0.45 + r) * arms * 0.55;
        col += mix(pal(HUE + 0.3), float3(1.0), 0.6) * exp(-r * 9.0) * (0.6 + 0.6 * BEAT);
    }
    for (int j = 0; j < 4; j++) {                         // particle river in 4 layers
        float fj = float(j);
        float nJ = 48.0 + 24.0 * fj;
        float v = log(r + 0.04) * (4.0 + fj * 1.5) + t * (0.28 + 0.07 * fj);
        float uu = (a + log(r + 0.04) * (1.2 + 0.4 * fj)) / 6.28318 * nJ;
        float ci = floor(uu), vi = floor(v);
        float cm = ci - nJ * floor(ci / nJ);
        float h1 = hash21(float2(cm, vi + 31.0 * fj));
        if (h1 > 0.5) {
            float2 f = float2(fract(uu), fract(v));
            float2 o = float2(hash21(float2(cm, vi + 3.3 + fj)), hash21(float2(cm + 9.1, vi + fj)));
            float dx = (f.x - o.x) * 6.28318 * r / nJ, dy = (f.y - o.y) * (r + 0.04) / (4.0 + fj * 1.5);
            float g = exp(-(dx * dx / (0.0065 * 0.0065) + dy * dy / (0.03 * 0.03)));
            col += mix(pal(HUE + 0.15 * fj), float3(1.0), 0.35) * g * (0.9 + 1.2 * h1) * (0.8 + 0.4 * BEAT) * smoothstep(0.03, 0.2, r) * smoothstep(2.0, 0.9, r);
        }
    }
    for (int i = 0; i < 4; i++) {
        float3 ck = clickAt(u, i); if (ck.z > 2.5) continue;
        float2 dd = p - ck.xy; float rr = length(dd);
        col += (pal(HUE + 0.1 + float(i) * 0.15) * 0.6 + 0.6) * exp(-pow((rr - ck.z * 0.8) * 6.0, 2.0)) * exp(-ck.z * 0.9) * 1.7;
    }
    return col;
}

// ---- 28 flower: layered petals + golden-angle seed head, opens and breathes with the bass; clicks send a bloom ring
float3 flower(float2 p, constant float *u, float aspect) {
    float t = TIME, tb = BCLK;
    float2 st = steer(u, aspect);
    float2 c = float2(0.03 * sin(t * 0.2), 0.03 * cos(t * 0.17)) + st * float2(0.4 * aspect, 0.35);
    float2 q = p - c; float r = length(q), a = atan2(q.y, q.x);
    float open = 0.86 + 0.14 * sin(tb * 0.3927);                   // one breath per 16 beats
    float breathe = open * (1.0 + 0.04 * BASS + 0.05 * KICK);
    float3 col = pal(HUE + 0.6) * exp(-r * 2.2) * 0.07;
    for (int L = 0; L < 6; L++) {
        float fl = float(L);
        float rot = fl * 0.3927 + t * 0.035 * (fmod(fl, 2.0) < 0.5 ? 1.0 : -1.0);
        float Rl = (1.04 - 0.15 * fl) * breathe;
        float lobe = pow(abs(cos(4.0 * (a - rot))), 0.65);
        float pr = Rl * (0.3 + 0.7 * lobe);
        float inside = smoothstep(pr, pr - 0.012, r);
        float grad = r / max(pr, 1e-3);
        float3 lc = pal(HUE + fl * 0.11 + grad * 0.22) * (0.25 + 0.95 * pow(grad, 1.3));
        lc += float3(1.0, 0.95, 0.9) * exp(-abs(r - pr) * 70.0) * 0.4;
        lc += pal(HUE + 0.5 + fl * 0.1) * exp(-abs(sin(4.0 * (a - rot))) * 16.0) * 0.18 * grad;      // veins
        col = mix(col, lc, inside * 0.93);
    }
    float seedR = 0.3 * breathe;
    if (r < seedR + 0.02) {
        col = mix(col, float3(0.015, 0.01, 0.02), smoothstep(seedR + 0.012, seedR, r));
        const float cc = 0.0125;
        float n0 = floor(r * r / (cc * cc)), best = 1e5, bn = 0.0;
        for (int k = -22; k <= 22; k++) {
            float n = n0 + float(k); if (n < 0.0) continue;
            float th = n * 2.39996323 + t * 0.06;
            float2 sp = cc * sqrt(n) * float2(cos(th), sin(th));
            float dd = length(q - sp);
            if (dd < best) { best = dd; bn = n; }
        }
        float dot_ = smoothstep(cc * 0.5, cc * 0.3, best);
        float wave = exp(-pow(fract(bn * 0.004 - tb * 0.125) - 0.5, 2.0) * 60.0);
        col += pal(HUE + 0.55 + bn * 0.0035) * dot_ * (0.7 + 0.9 * wave + 0.4 * KICK) * smoothstep(seedR + 0.012, seedR - 0.02, r);
    }
    for (int i = 0; i < 4; i++) {
        float3 ck = clickAt(u, i); if (ck.z > 3.0) continue;
        float rr = length(p - ck.xy);
        col += pal(HUE + 0.2 + float(i) * 0.2) * exp(-pow((rr - ck.z * 0.55) * 10.0, 2.0)) * exp(-ck.z * 0.9) * 0.9;
    }
    return col;
}

// ---- 31 fireworks: beat-scheduled shells (analytic sparks) + click-launched shells + pointer sparkler; feedback gives the trails
float3 fwBurst(float2 p, float2 c, float tau, float seed, float3 colr, int N) {
    if (tau < -1.0 || tau > 7.0) return float3(0.0);
    if (tau < 0.0) {                                           // rocket rising
        float k = 1.0 + tau;
        float2 rp = float2(c.x, mix(-0.72, c.y, 1.0 - (1.0 - k) * (1.0 - k)));
        return float3(1.0, 0.85, 0.6) * exp(-length(p - rp) * 120.0) * 0.5;
    }
    float R = 0.6 * (1.0 - exp(-tau * 1.5));                   // shells stay inside the frame: centre margin + max radius < screen edge
    float2 g = float2(0.0, -0.04 * tau * tau);
    float2 rel = p - c - g;
    if (length(rel) > R * 1.05 + 0.08) return float3(0.0);
    float acc = 0.0, f = exp(-tau * 0.4) * smoothstep(0.0, 0.08, tau);
    float pang = atan2(rel.y, rel.x); if (pang < 0.0) pang += 6.28318;
    int c0 = int(floor(pang / 6.28318 * float(N)));
    for (int j = -2; j <= 2; j++) {                              // only the sparks angularly near this pixel matter
        int i = ((c0 + j) % N + N) % N;
        float fi = float(i);
        float ang = 6.28318 * (fi + hash21(float2(fi, seed))) / float(N);
        float sp = 0.4 + 0.6 * hash21(float2(fi + 17.0, seed + 2.0));      // filled burst (inner sparks too), not a hollow ring
        float2 pos = float2(cos(ang), sin(ang)) * sp * R;
        float dd = length(rel - pos);
        acc += (exp(-dd * 110.0) + 0.1 * exp(-dd * 30.0)) * (0.6 + 0.4 * sin(tau * 25.0 + fi * 1.7));     // crisp hot core + faint halo
    }
    float flash = exp(-length(rel) * 7.0) * exp(-tau * 5.0) * 0.9;           // hot core at the instant of the burst (small, short: not a screen flash)
    return mix(float3(1.0, 0.92, 0.8), colr, smoothstep(0.0, 1.2, tau)) * (acc * f * 1.7 + flash);
}
float3 fireworks(float2 p, constant float *u, float aspect, float fr) {
    float t = TIME, tb = BCLK;
    float3 col = float3(0.0);
    for (int m = 0; m < 4; m++) {                              // one shell every 2 beats, up to 4 alive
        float k = floor(tb / 2.0) - float(m);
        float tau = (tb - 2.0 * k) - 1.0;
        float2 cc = float2((hash21(float2(k, 1.7)) - 0.5) * 2.0 * (aspect - 0.72), 0.0 + 0.34 * hash21(float2(k, 5.3)));
        col += fwBurst(p, cc, tau, k, pal(HUE + hash21(float2(k, 9.1)) * 0.9 + 0.15 * float(m)), 56);
    }
    for (int i = 0; i < 4; i++) {                              // clicks launch shells where you click
        float3 ck = clickAt(u, i); if (ck.z > 5.0) continue;
        col += fwBurst(p, ck.xy, ck.z * 1.8 - 0.0, ck.x * 13.0 + ck.y * 7.0, pal(HUE + hash21(ck.xy * 17.0) + 0.5), 40);
    }
    for (int i = 0; i < 3; i++) {                              // sparkler under the pointer
        float s = ptrStr(u, i); if (s <= 0.0) continue;
        float2 pp = ptrPos(u, i);
        col += float3(1.0, 0.85, 0.55) * exp(-length(p - pp) * 45.0) * s * 0.7;
        for (int k = 0; k < 4; k++) {
            float2 off = (hash22(float2(float(k) + float(i) * 7.0, floor(t * 24.0))) - 0.5) * 0.09;
            col += pal(HUE + 0.1 * float(k)) * exp(-length(p - pp - off) * 100.0) * s * 0.7;
        }
    }
    return col * fr;
}
float2 fwSky(float2 p, float aspect) {    // skyline silhouette: x = 1 inside a building, y = lit window
    float x = (p.x / aspect) * 0.5 + 0.5;
    float col = floor(x * 22.0);
    float hgt = -0.74 + 0.07 + 0.16 * pow(hash21(float2(col, 2.0)), 1.6) + 0.04 * hash21(float2(col, 9.0));
    float mask = step(p.y, hgt) * step(0.06, fract(x * 22.0)) * step(fract(x * 22.0), 0.94);
    float2 cell = float2(floor(x * 22.0 * 3.0), floor((p.y + 1.0) * 26.0));
    float lit = mask * step(0.72, hash21(cell + 11.0)) * step(0.15, fract(x * 66.0)) * step(fract(x * 66.0), 0.85) * step(0.2, fract((p.y + 1.0) * 26.0)) * step(fract((p.y + 1.0) * 26.0), 0.8);
    return float2(mask, lit);
}

// ---- 29 coral (Gray-Scott reaction-diffusion) and 30 pond (wave equation): simulated in a small texture by `vsim`, shaded here
float3 coralShade(float2 uv, constant float *u, texture2d<float> simt) {
    float2 suv = 0.5 + (uv - 0.5) * 0.6;                    // show the central 60 % of the sim: pattern reads ~1.7x larger and calmer than the raw 640x360 maze
    float2 px = float2(1.0 / 640.0, 1.0 / 360.0);
    float2 s = simt.sample(fb, suv).rg;
    float bl = simt.sample(fb, suv - float2(px.x, 0)).g, br = simt.sample(fb, suv + float2(px.x, 0)).g;
    float bu = simt.sample(fb, suv - float2(0, px.y)).g, bd = simt.sample(fb, suv + float2(0, px.y)).g;
    float b = s.g, a = s.r;
    float2 gr = float2(br - bl, bd - bu);
    float3 n = normalize(float3(-gr.x * 7.0, gr.y * 7.0, 1.0));
    float ang = TIME * 0.12;
    float3 L = normalize(float3(cos(ang) * 0.7, sin(ang) * 0.7, 0.8));
    float diff = clamp(dot(n, L), 0.0, 1.0);
    float spc = pow(clamp(dot(reflect(-L, n), float3(0, 0, 1)), 0.0, 1.0), 36.0);
    float hgt = smoothstep(0.02, 0.3, b);
    float3 base = pal(HUE + b * 1.6 + a * 0.2 + (uv.x - 0.5) * 0.15);
    float3 albedo = mix(float3(0.008, 0.012, 0.035), base, hgt);
    float3 col = albedo * (0.2 + 1.0 * diff);
    col += pal(HUE + 0.5) * (1.0 - hgt) * 0.035;                    // faint glow in the valleys
    col += pal(HUE + 0.3) * clamp(length(gr) * 9.0, 0.0, 1.0) * 0.45;   // glossy rim along the ridges
    col += float3(1.0) * spc * (0.15 + 0.6 * hgt);
    float aspect = RES_X / RES_Y;
    float2 pq = float2((uv.x * 2.0 - 1.0) * aspect, 1.0 - uv.y * 2.0);
    for (int i = 0; i < 3; i++) {                                       // each pointer is a moving light that rakes across the coral
        float s = ptrStr(u, i); if (s <= 0.0) continue;
        float2 dv = ptrPos(u, i) - pq;
        float3 Lp = normalize(float3(dv, 0.3));
        float fall = exp(-dot(dv, dv) * 2.5) * s;
        col += (albedo * max(dot(n, Lp), 0.0) * 2.2 + float3(1.0, 0.95, 0.85) * pow(max(dot(reflect(-Lp, n), float3(0, 0, 1)), 0.0), 28.0) * 0.9) * fall;
        col += pal(HUE + 0.2) * exp(-dot(dv, dv) * 900.0) * s * 0.8;
    }
    col *= 0.85 + 0.3 * BEAT;
    return col;
}
float3 pondShade(float2 uv, constant float *u, texture2d<float> simt) {
    float2 px = float2(1.0 / 640.0, 1.0 / 360.0);
    float h = simt.sample(fb, uv).r;
    float hl = simt.sample(fb, uv - float2(px.x, 0)).r, hr = simt.sample(fb, uv + float2(px.x, 0)).r;
    float hu = simt.sample(fb, uv - float2(0, px.y)).r, hd = simt.sample(fb, uv + float2(0, px.y)).r;
    float2 gr = float2(hr - hl, hd - hu);
    float lap = hl + hr + hu + hd - 4.0 * h;
    float2 gs = gr * 170.0 / (1.0 + 130.0 * length(gr));    // compress strong slopes so faint old rings stay readable (gain ~3x vs first version)
    float3 n = normalize(float3(-gs.x, gs.y, 1.0));
    float lit = clamp(dot(n, normalize(float3(0.4, 0.6, 0.75))), 0.0, 1.0);
    float3 base = mix(float3(0.02, 0.05, 0.14), pal(HUE + 0.6) * 0.2, smoothstep(1.0, 0.0, uv.y));
    float3 env = pal(HUE + 0.55 + n.x * 0.15 + n.y * 0.1) * pow(1.0 - n.z, 0.9) * 2.0;
    float caustic = clamp(-lap * 60.0, 0.0, 1.0);
    return base + env + float3(1.0) * pow(lit, 36.0) * 0.9 + pal(HUE + 0.45) * caustic * 0.9 + float3(0.02, 0.05, 0.1) * (1.0 + 4.0 * h);
}

// ---- 32 silk (visuals pack 2): translucent aurora curtains + swooping ribbons over a glossy black floor.
// Curtains are folded sheets seen edge-on (ridge = bright vertical band) with fine vertical rays; the bar-synced sway and a travelling
// shimmer sweep ride the beat clock. Pointers part the curtains and drag the hem down, ribbons bend toward them, clicks send a shock wave along x.
float3 silkSheet(float2 p, constant float *u, float aspect, float tb, float t) {
    float3 col = float3(0.0);
    float bp = floor(tb) + (1.0 - exp(-6.0 * fract(tb))) / (1.0 - exp(-6.0));          // eased beat clock: each beat is a soft push
    float sweep = fract(tb * 0.125) * 2.4 - 1.2;                                         // shimmer crosses the stage every 8 beats
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float x = p.x * (0.62 + 0.13 * fi) + fi * 2.7;
        float sway = sin(p.y * 0.9 + tb * 0.11 + fi * 1.7) * 0.16 + sin(p.y * 2.1 - tb * 0.17 + fi * 2.3) * 0.06 + 0.45 * sin(p.x * 0.8 + fi * 2.1 + tb * 0.05) + 0.03 * sin(bp * 1.5708 + fi);   // mostly vertical sheets that meander sideways
        float push = 0.0, pull = 0.0;
        for (int k = 0; k < 3; k++) {                                                    // pointers part the curtain and pull the hem down
            float s = ptrStr(u, k); if (s <= 0.0) continue;
            float2 d = p - ptrPos(u, k); float w = exp(-dot(d, d) * 3.5) * s;
            push += d.x * w * 1.3 - ptrVel(u, k).x * 0.25 * w; pull += w;
        }
        float shock = 0.0;
        for (int k = 0; k < 4; k++) {
            float3 ck = clickAt(u, k); if (ck.z > 3.0) continue;
            float r = abs(p.x - ck.x) - ck.z * 0.85;
            shock += exp(-r * r * 30.0) * exp(-ck.z * 0.9);
        }
        float sx = x + sway * 1.3 + push + shock * 0.25 * sin(p.y * 6.0 + fi);
        float ridge = pow(0.5 + 0.5 * sin(sx * 2.6 + fi * 1.3), 2.5);                    // sheet fold seen edge-on
        float hem = 0.05 + 0.3 * sin(x * 0.9 + fi * 2.0 + tb * 0.05) - 0.12 * fi - pull * 0.45 + 0.04 * (exp(-fract(tb) * 5.0) - 0.3);
        float a = p.y - hem;
        float body = a > 0.0 ? exp(-a * (0.75 + 0.2 * fi)) : exp(a * 38.0);
        float rays = 0.45 + 0.55 * vnoise2(float2(sx * 20.0, 1.0 + fi + t * 0.12 + p.y * 0.15));
        float fine = 0.85 + 0.15 * sin(sx * 60.0);                                          // vertical fibres only: no cross-hatch moire
        float lift = 0.55 + 0.9 * BEAT * (0.5 + 0.5 * exp(-abs(a) * 3.0)) + 1.1 * exp(-pow((p.x / aspect - sweep) * 4.0, 2.0)) * 0.5 + shock * 0.8 + pull * 0.6;
        float3 c = pal(HUE + fi * 0.045 + clamp(a, -0.3, 1.2) * 0.25 + 0.15 * ridge);
        col += c * body * (0.2 + 0.9 * ridge) * rays * fine * lift * 0.3;
        col += pal(HUE + 0.5 + fi * 0.06) * exp(-abs(a) * 30.0) * ridge * 0.9 * (1.0 + 1.5 * BEAT);   // hot hem line
    }
    for (int j = 0; j < 2; j++) {                                                        // swooping ribbons with a bright filament along the edge
        float fj = float(j);
        float yc = 0.32 * sin(p.x * (0.75 + 0.2 * fj) + fj * 2.4 + tb * (0.07 - 0.03 * fj)) + 0.28 - 0.62 * fj;
        for (int k = 0; k < 3; k++) {
            float s = ptrStr(u, k); if (s <= 0.0) continue;
            float2 d = p - ptrPos(u, k); yc += (ptrPos(u, k).y - yc) * exp(-d.x * d.x * 2.0) * s * 0.55;
        }
        float dy = p.y - yc;
        float tw = cos(p.x * 2.0 + tb * 0.1 + fj * 1.9);                                  // twist: the ribbon flips colour at its folds
        float thick = 0.02 + 0.05 * abs(tw);
        float3 c = pal(HUE + 0.3 + fj * 0.3 + 0.2 * tw);
        col += c * exp(-abs(dy) / thick) * (0.22 + 0.18 * BEAT) * (0.4 + 0.6 * abs(tw));
        col += mix(c, float3(1.0), 0.5) * exp(-abs(dy - thick * 1.2 * clamp(tw * 4.0, -1.0, 1.0)) * 160.0) * 0.45;
    }
    return col;
}
float3 silk(float2 p, constant float *u, float aspect) {
    float t = TIME, tb = BCLK;
    float fy = -0.66;                                                                    // floor line
    float3 col;
    if (p.y > fy) col = silkSheet(p, u, aspect, tb, t);
    else {                                                                               // glossy floor: rippled, smeared mirror at ~35 %
        float k = (fy - p.y);
        float2 q = float2(p.x + 0.025 * sin(p.y * 38.0 + t * 1.3) * (0.4 + k), fy + k * 0.8);
        col = 0.5 * (silkSheet(q + float2(0.04, 0.0), u, aspect, tb, t) + silkSheet(q - float2(0.04, 0.0), u, aspect, tb, t)) * 0.5 * exp(-k * 1.8);
        col += pal(HUE + 0.4) * exp(-k * 14.0) * 0.05;
    }
    col += pal(HUE + 0.45) * exp(-abs(p.y - fy) * 45.0) * 0.12 * (1.0 + BEAT);        // horizon glint where curtains meet the gloss
    col += pal(HUE + 0.6) * (0.015 + 0.02 * vnoise2(float2(p.x * 4.0, p.y * 1.5 + t * 0.03)));        // faint backdrop drapes
    col *= smoothstep(1.9, 0.5, length(p * float2(0.75, 1.0)));                          // vignette: dark centre-void feel at the edges
    return col;
}

// ---------- pass 1: warp previous frame + draw new shapes (writes the feedback texture)
fragment float4 vwarp(VOut in [[stage_in]], constant float *u [[buffer(0)]], constant float *wave [[buffer(1)]],
                      constant float *spec [[buffer(2)]], constant float *peaks [[buffer(3)]],
                      texture2d<float> prev [[texture(0)]], texture2d<float> simt [[texture(1)]]) {
    float aspect = RES_X / RES_Y;
    float2 uv = in.uv;
    float2 p = float2((uv.x * 2.0 - 1.0) * aspect, 1.0 - uv.y * 2.0);   // y up, -1..1 (uv is texture space, top = 0)
    int P = int(PRESET);
    float t = TIME, e = ENERGY, tb = BCLK;
    float hue = HUE;

    // per-preset motion of the old frame
    float zoom = 1.0, ang = 0.0, decay = 0.9;
    float2 disp = float2(0.0);
    if (P == 0) { zoom = 0.978 - 0.015 * KICK - 0.02 * DROP; ang = 0.012 * sin(t * 0.3) + 0.01; decay = 0.945; }
    else if (P == 1) { zoom = 1.0; decay = 0.72; }
    else if (P == 2) { zoom = 1.014 + 0.008 * BASS + 0.012 * KICK; ang = 0.012 + 0.008 * sin(t * 0.2); decay = 0.965; }
    else if (P == 3) {
        zoom = 0.985 - 0.015 * BASS - 0.012 * KICK; decay = 0.965;
        disp = 0.007 * (1.0 + 2.0 * BASS) * float2(sin(p.y * 4.0 + t * 0.9) + sin(p.y * 9.0 - t * 1.3), cos(p.x * 3.0 - t * 0.7) + cos(p.x * 7.0 + t));
    }
    else if (P == 4) { zoom = 0.985 - 0.01 * KICK; ang = -0.012; decay = 0.86; }
    else if (P == 5) { zoom = 1.0; decay = 0.55; disp = float2(0.0, 0.004); }
    else if (P == 6) { zoom = 0.982 - 0.01 * KICK - 0.015 * DROP; decay = 0.94; }   // slow drift, not warp speed
    else if (P == 14) { decay = 0.975; disp = float2(0.0, -0.0045); zoom = 0.996; }
    else if (P == 17) { decay = 0.88; zoom = 0.992; ang = 0.004; }
    else if (P == 23) { zoom = 1.0; decay = 0.9965; disp = inkDisp(p, u); }           // ink in water
    else if (P == 31) { zoom = 1.0; decay = 0.93; disp = float2(0.0, 0.0008); }       // fireworks: trails sink slowly
    else if (P == 32) { zoom = 1.0; decay = 0.4; }                                  // silk: short shimmer trails
    else { decay = 0.0; }

    float3 old = float3(0.0);
    if (decay > 0.0) {
        float fr = clamp(FRAMES, 0.25, 4.0);
        float2 q = rot(p, ang * fr) * pow(zoom, fr) + disp * fr;
        float2 suv = float2((q.x / aspect) * 0.5 + 0.5, 0.5 - q.y * 0.5);
        old = prev.sample(fb, suv).rgb * pow(decay, fr);
        if (P == 3) old = hueShift(old, 0.02);   // colours drift like MilkDrop
        if (P == 2) old = hueShift(old, 0.008);
        if (P == 23) {          // soft diffusion of the ink + slow colour drift
            float2 o = float2(1.3 / RES_X, 1.3 / RES_Y);
            float3 nb = prev.sample(fb, suv + float2(o.x, 0)).rgb + prev.sample(fb, suv - float2(o.x, 0)).rgb + prev.sample(fb, suv + float2(0, o.y)).rgb + prev.sample(fb, suv - float2(0, o.y)).rgb;
            old = (0.6 * prev.sample(fb, suv).rgb + 0.1 * nb) * pow(decay, fr);
            old = min(hueShift(old, 0.003 * fr), float3(3.0));
        }
    }

    float3 nw = float3(0.0);
    float r = length(p), a = atan2(p.y, p.x);
    if (P == 0) {               // WMP Ambience/Battery: circular waveform + rays on kicks
        float R = 0.28 + 0.12 * KICK + 0.1 * DROP;
        float w = waveAt(wave, fract(a / (2.0 * PI) + 0.5));
        float d = abs(r - (R + 0.22 * w));
        nw += pal(hue + a / (2.0 * PI)) * exp(-d * 180.0) * 1.4;
        float rays = pow(abs(sin(a * 12.0 + t * 0.5)), 40.0) * smoothstep(0.1, 0.6, r) * KICK;
        nw += pal(hue + 0.5) * rays * 0.6;
    } else if (P == 1) {        // oscilloscope
        float d = scopeDist(p, wave, aspect, 0.55, 0.0);
        nw += float3(0.25, 1.0, 0.45) * (exp(-d * 260.0) * 1.6 + exp(-d * 30.0) * 0.12);
    } else if (P == 2) {        // iTunes Classic: spectrum ring feeding a spinning tunnel
        float s = specAt(spec, abs(fract(a / (2.0 * PI) + 0.25) - 0.5) * 2.0);
        float R = 0.95 + 0.35 * s;   // drawn wide; the inward zoom pulls it into the tunnel
        float d = abs(r - R);
        nw += pal(hue + a / PI * 0.5 + s) * exp(-d * 120.0) * (0.4 + 1.6 * s) * (0.65 + 0.7 * BEAT);
        nw += pal(hue + 0.3) * exp(-r * 18.0) * BEAT * 0.8;
    } else if (P == 3) {        // MilkDrop: thick wandering waveform
        float y0 = 0.35 * sin(t * 0.37);
        float d = scopeDist(rot(p, 0.4 * sin(t * 0.21)), wave, aspect, 0.4 + 0.4 * e, y0);
        nw += pal(hue + p.x * 0.2) * exp(-d * 90.0) * 1.3 * (0.75 + 0.6 * BEAT);
        nw += float3(1.0) * exp(-d * 400.0) * 0.6 * BEAT;
    } else if (P == 4) {        // AVS kaleido rings (mirrored in the composite pass)
        float s = specAt(spec, fract(r * 0.8));
        // thin spectrum-lit rings + a waveform loop; dark gaps keep the kaleidoscope readable
        float ringd = abs(fract(r * 4.0 - tb * 0.25) - 0.5);
        nw += pal(hue + r * 0.7) * exp(-ringd * 90.0) * s * 0.45;
        float w = waveAt(wave, fract(a / (2.0 * PI)));
        nw += pal(hue + 0.5 + a * 0.1) * exp(-abs(r - 0.45 - 0.2 * w) * 160.0) * 0.8;
        nw += pal(hue + 0.2) * exp(-abs(abs(p.x) - 0.3 - 0.2 * w) * 200.0) * 0.4 * BEAT;
    } else if (P == 5) {        // Winamp spectrum bars with falling peak caps
        float x = (p.x / aspect) * 0.5 + 0.5;
        float nb = 64.0; float bi = floor(x * nb); float fx = fract(x * nb);
        float v = specAt(spec, (bi + 0.5) / nb);
        float pk = peaks[clamp(int((bi + 0.5) / nb * 127.0), 0, 127)];
        float y = p.y * 0.5 + 0.5;            // 0 bottom .. 1 top
        float base = 0.12;
        float h = base + v * 0.78;
        float bar = step(0.12, fx) * step(fx, 0.88) * step(base, y) * step(y, h);
        float3 grad = mix(float3(0.1, 1.0, 0.2), float3(1.0, 0.9, 0.1), smoothstep(0.3, 0.6, y));
        grad = mix(grad, float3(1.0, 0.15, 0.1), smoothstep(0.65, 0.85, y));
        float seg = step(0.25, fract(y * 60.0));   // LED-segment look
        nw += grad * bar * seg;
        float cap = step(0.12, fx) * step(fx, 0.88) * smoothstep(0.006, 0.0, abs(y - (base + pk * 0.78) - 0.008));
        nw += float3(1.0) * cap;
        float refl = step(0.12, fx) * step(fx, 0.88) * step(y, base) * step(base - (h - base) * 0.35, y);
        nw += grad * refl * 0.18;
    } else if (P == 6) {        // hyperspace starburst: fresh stars each frame, zoom smears them into streaks
        float2 g = p * 40.0, cell = floor(g);
        float fr = floor(t * 30.0);
        float hsh = hash21(cell + fr);
        float2 sp = float2(hash21(cell + fr + 3.1), hash21(cell + fr + 7.7));
        float pt = exp(-length(fract(g) - sp) * 18.0);                       // tiny round point inside the cell
        float star = step(0.978 - 0.01 * e - 0.02 * KICK, hsh) * pt * smoothstep(0.05, 0.3, r);
        nw += mix(float3(1.0), pal(hue + hsh), 0.5) * star * 3.2 * (0.7 + 0.8 * BEAT);
        nw += pal(hue) * exp(-abs(r - 1.2 * fract(BCLK)) * 60.0) * (1.0 - fract(BCLK)) * KICK * 0.8;
    } else if (P == 8) {
        nw = fractalCathedral(p, u);
    } else if (P == 9) {
        nw = wormhole(p, u);
    } else if (P == 10) {
        nw = liquidChrome(p, u);
    } else if (P == 11) { nw = synthwave(p, u);
    } else if (P == 12) { nw = crystals(p, u, spec);
    } else if (P == 13) { nw = truchet(p, u);
    } else if (P == 14) { nw = waterfallLine(p, u, spec, aspect);
    } else if (P == 15) { nw = galaxy(p, u);
    } else if (P == 16) { nw = mandala(p, u, spec);
    } else if (P == 17) { nw = lissajous(p, u, wave, aspect);
    } else if (P == 18) { nw = audioSphere(p, u, spec);
    } else if (P == 19) { nw = northernLights(p, u);
    } else if (P == 20) { nw = nebula(p, u);
    } else if (P == 21) { nw = glyphRain(p, u, aspect);
    } else if (P == 22) { nw = hyperdrive(p, u);
    } else if (P == 23) { nw = inkWater(p, u, aspect);
    } else if (P == 24) { nw = neonCity(p, u, spec, aspect);
    } else if (P == 25) { nw = laserGrid(p, u, aspect);
    } else if (P == 26) { nw = terrain(p, u, aspect);
    } else if (P == 27) { nw = portal(p, u, aspect);
    } else if (P == 28) { nw = flower(p, u, aspect);
    } else if (P == 29) { nw = coralShade(in.uv, u, simt);
    } else if (P == 30) { nw = pondShade(in.uv, u, simt);
    } else if (P == 31) { nw = fireworks(p, u, aspect, clamp(FRAMES, 0.25, 4.0));
    } else if (P == 32) { nw = silk(p, u, aspect);
    } else {                    // plasma (no feedback)
        float2 q = p * (1.5 + 0.5 * sin(t * 0.1));
        float v = sin(q.x * 3.0 + t) + sin(q.y * 4.0 - t * 1.3) + sin((q.x + q.y) * 2.5 + t * 0.7) + sin(length(q) * 6.0 - t * 2.0 - BASS * 4.0);
        nw = pal(hue + v * 0.15 + tb * 0.03) * (0.55 + 0.45 * sin(v * 2.0)) * (0.7 + 0.5 * BEAT);
    }
    float3 outc = old + nw;
    if (P == 31) {              // skyline occludes the sky and its windows glow
        float2 sk = fwSky(p, aspect);
        outc = outc * (1.0 - sk.x) + float3(0.01, 0.006, 0.016) * sk.x + float3(1.0, 0.7, 0.35) * sk.y * (0.18 + 0.12 * BEAT);
    }
    return float4(outc, 1.0);
}

// ---------- pass 2: composite to screen
fragment float4 vcomp(VOut in [[stage_in]], constant float *u [[buffer(0)]], texture2d<float> cur [[texture(0)]]) {
    float aspect = RES_X / RES_Y;
    float2 uv = in.uv;
    int P = int(PRESET);
    if (P == 4) {               // 6-fold kaleidoscope
        float2 p = float2((uv.x * 2.0 - 1.0) * aspect, uv.y * 2.0 - 1.0);
        float a = atan2(p.y, p.x), r = length(p);
        float seg = PI / 3.0;
        a = abs(fmod(a + TIME * 0.05 + 10.0 * PI, seg) - seg * 0.5);
        p = r * float2(cos(a), sin(a));
        uv = float2((p.x / aspect) * 0.5 + 0.5, p.y * 0.5 + 0.5);
    }
    float3 c = cur.sample(fb, uv).rgb;
    if (P == 1) {               // CRT: scanlines + vignette
        c *= 0.8 + 0.2 * sin(uv.y * RES_Y * 1.5);
        float2 v = uv - 0.5; c *= smoothstep(0.85, 0.3, length(v * float2(1.0, 1.2)));
    }
    // gentle grid-locked lift for presets whose own motion is slow/accumulating (ink, terrain, flower, pond, fireworks): the picture breathes on the beat
    c *= 1.0 + BEAT * (P == 23 ? 0.12 : P == 26 ? 0.14 : P == 28 ? 0.10 : P == 30 ? 0.16 : P == 31 ? 0.12 : 0.0);
    c = 1.0 - exp(-c * 1.4);
    c += (hash21(in.uv * float2(RES_X, RES_Y) + fract(TIME) * 37.0) - 0.5) * (2.0 / 255.0);     // dither: no banding in dark gradients
    c *= mix(0.5, 1.0, FADE);
    c += STROBE * 1.5;
    c *= 1.0 - BLACKOUT;
    return float4(c, 1.0);
}

// ---------- simulation pass for Coral (Gray-Scott) and Pond (wave equation); state lives in a 640x360 half-float texture
fragment float4 vsim(VOut in [[stage_in]], constant float *u [[buffer(0)]], texture2d<float> prev [[texture(0)]]) {
    float aspect = RES_X / RES_Y;
    float2 uv = in.uv, px = float2(1.0 / 640.0, 1.0 / 360.0);
    float2 p = float2((uv.x * 2.0 - 1.0) * aspect, 1.0 - uv.y * 2.0);
    int P = int(PRESET); float t = TIME;
    if (P == 29) p /= 0.6;                                    // Coral is shown at 60 % crop (coralShade): keep painting/seeding in screen space
    bool reset = u[53] > 0.5;
    float4 c = prev.sample(fb, uv);
    if (P == 29) {
        float a = c.r, b = c.g;
        float lapA = -a, lapB = -b;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            float w = (dx == 0 || dy == 0) ? 0.2 : 0.05;
            float2 s = prev.sample(fb, uv + float2(float(dx), float(dy)) * px).rg;
            lapA += w * s.r; lapB += w * s.g;
        }
        int vi = int(VAR * 2.999);
        float F = vi == 0 ? 0.0545 : (vi == 1 ? 0.039 : 0.0367), k = vi == 0 ? 0.062 : (vi == 1 ? 0.058 : 0.0649);
        F += 0.013 * sin(p.x * 1.1 + t * 0.04 + VAR * 6.0) * sin(p.y * 0.9 - t * 0.035) + 0.004 * sin(p.x * 3.0 + t * 0.05);     // slow patches drift between maze, spots and bare rest areas
        float uvv = (1.0 - a) * b * b;
        float dU = -1.0 * lapA - uvv + F * a;          // Du = 1.0, Dv = 0.5 with the 0.2/0.05 nine-point stencil (Karl Sims' formulation)
        float dV = 0.5 * lapB + uvv - (F + k) * b;
        a -= dU; b += dV;
        if (reset) { a = 0.0; b = 0.0; }
        float seed = 0.0, initSeed = 0.0;
        if (reset) for (int i = 0; i < 90; i++) { float2 sp = (hash22(float2(float(i), 4.4)) - 0.5) * float2(2.1 * aspect, 2.1); initSeed = max(initSeed, step(length(p - sp), 0.05)); }
        if (KICK > 0.6 && fmod(floor(BCLK), 4.0) < 0.5) { float2 sp = (hash22(float2(floor(BCLK), 8.8)) - 0.5) * float2(1.8 * aspect, 1.7); seed = max(seed, step(length(p - sp), 0.025)); }     // one new colony per bar (calm at the drop too)
        float paint = 0.0;
        for (int i = 0; i < 3; i++) {
            float s = ptrStr(u, i); if (s <= 0.0) continue;
            paint = max(paint, step(length(p - ptrPos(u, i)), 0.005 + 0.006 * s));
        }
        for (int i = 0; i < 4; i++) { float3 ck = clickAt(u, i); if (ck.z < 0.12) seed = max(seed, step(length(p - ck.xy), 0.06)); }
        if (initSeed > 0.5) { a = 0.5; b = 0.5; }          // opening colonies
        else if (seed > 0.5) b = max(b, 0.4);               // kick / click: inject V only, the pattern re-grows instead of dying
        else if (paint > 0.5) b = max(b, 0.3);
        return float4(clamp(a, 0.0, 1.0), clamp(b, 0.0, 1.0), 0.0, 1.0);
    }
    // P == 30: damped 2D wave equation, h in r, previous h in g
    float h = c.r, hp = c.g;
    float lap = prev.sample(fb, uv - float2(px.x, 0)).r + prev.sample(fb, uv + float2(px.x, 0)).r + prev.sample(fb, uv - float2(0, px.y)).r + prev.sample(fb, uv + float2(0, px.y)).r - 4.0 * h;
    float hn = (2.0 * h - hp + 0.42 * lap) * 0.99985;                      // rings live longer (was 0.9996)
    hn = mix(hn, h + 0.25 * lap, 0.03);                                    // a little viscosity: kills fine moire
    float2 e = min(uv, 1.0 - uv) / px;
    hn *= mix(0.94, 1.0, smoothstep(0.0, 10.0, min(e.x, e.y)));          // absorbing rim: calm edges
    float2 d;
    for (int k = 0; k < 3; k++) {                                          // ambient raindrops, three staggered streams
        float rate = k == 0 ? 0.5 : (k == 1 ? 0.25 : 0.125);                // drops land on the beat clock: every 2 beats / bar / 2 bars (+ one kick drop per beat below)
        float id = floor(BCLK * rate), f = fract(BCLK * rate) / rate * 1.6;
        float2 pos = (hash22(float2(id, 5.1 + 3.0 * float(k))) - 0.5) * float2(1.8 * aspect * 0.9, 1.6);
        d = p - pos;
        hn += 0.11 * exp(-f * 4.0) * sin(f * 50.0) * exp(-dot(d, d) / 0.0012) * step(f, 0.5);     // short ring train per drop
    }
    float2 kp = (hash22(float2(floor(BCLK), 2.2)) - 0.5) * float2(1.6 * aspect, 1.4);
    d = p - kp; hn += 0.08 * KICK * KICK * exp(-dot(d, d) / 0.002);       // kick drops
    for (int i = 0; i < 3; i++) {
        float s = ptrStr(u, i); if (s <= 0.0) continue;
        d = p - ptrPos(u, i);
        hn -= 0.02 * s * clamp(length(ptrVel(u, i)) * 0.35, 0.0, 1.0) * exp(-dot(d, d) / 0.0012);
    }
    for (int i = 0; i < 4; i++) { float3 ck = clickAt(u, i); if (ck.z < 0.07) { d = p - ck.xy; hn += 0.07 * exp(-dot(d, d) / 0.002); } }
    if (reset) return float4(0.0, 0.0, 0.0, 1.0);
    return float4(clamp(hn, -2.0, 2.0), h, 0.0, 1.0);
}

"""#
