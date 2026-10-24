// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

// Metal source compiled at runtime (keeps SwiftPM simple; no metallib step).
let stageShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = p; return o;
}

// Uniform slots (keep in sync with Renderer.swift)
#define RES_X u[0]
#define RES_Y u[1]
#define TIME u[2]
#define ENERGY u[3]
#define SUB u[4]
#define BASS u[5]
#define LOWMID u[6]
#define MID u[7]
#define HIGH u[8]
#define KICK u[9]
#define SNARE u[10]
#define HAT u[11]
#define BEAT u[12]       // predicted-beat pulse 1 -> 0
#define PHASE u[13]      // beat phase 0..1
#define STROBE u[14]
#define BLACKOUT u[15]
#define FADE u[16]       // 0 idle .. 1 live
#define DROP u[17]
#define PALETTE u[18]
#define LASER u[19]
#define JUMP u[20]
#define HANDS u[21]
#define DENSITY u[22]
#define FIRE u[23]       // flame-jet envelope
#define SHAKE u[24]
#define BEATIDX u[25]
#define STAGE u[26]
#define LOOK u[27]       // LED wall content 0..5
#define BEAMPROG u[28]   // moving-head program 0..4
#define LASERPROG u[29]  // laser program 0..4
#define FIREBALL u[30]   // fireball age 0..1 (1 = done)
#define SPARKS u[31]     // spark fountain amount
#define CO2 u[32]        // CO2 cannon envelope
#define BLINDER u[33]    // blinder intensity
#define BUILD u[34]      // build-up amount
#define JETMASK u[35]    // which flame jets fire (bits 0..3)
#define SMOKE u[36]      // lingering smoke after pyro

constant float PI = 3.14159265;

float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float noise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}
float fbm(float2 p) { float a = 0.5, s = 0; for (int i = 0; i < 4; i++) { s += a * noise(p); p *= 2.03; a *= 0.5; } return s; }

float3 palette(float t, float pal) {
    float3 a = float3(0.5), b = float3(0.5), c = float3(1.0), d;
    int k = int(pal) % 4;
    if (k == 0) d = float3(0.00, 0.33, 0.67);
    else if (k == 1) d = float3(0.80, 0.90, 0.30);
    else if (k == 2) d = float3(0.00, 0.10, 0.20);
    else d = float3(0.55, 0.60, 0.70);
    return a + b * cos(6.28318 * (c * t + d));
}

float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0); return length(pa - ba * h);
}

// Thin beam from o along unit dir d (lasers).
float ray(float2 p, float2 o, float2 d, float w, float len) {
    float2 r = p - o; float a = dot(r, d);
    if (a < 0.0 || a > len) return 0.0;
    float c = abs(r.x * d.y - r.y * d.x);
    return exp(-c / w) * (1.0 - a / len);
}

float person(float2 p, float h, float jump, float hands, float seed) {
    p.y -= jump;
    float head = length(p - float2(0, 0.62 * h)) - 0.085 * h;
    float2 q = p - float2(0, 0.24 * h);
    float taper = mix(0.07, 0.10, clamp(q.y / (0.5 * h) + 0.5, 0.0, 1.0)) * h;
    float body = length(max(abs(q) - float2(taper, 0.26 * h), 0.0)) - 0.035 * h;
    float shoulders = length((p - float2(0, 0.47 * h)) / float2(1.0, 0.55)) - 0.13 * h;
    float neck = length(max(abs(p - float2(0, 0.54 * h)) - float2(0.03 * h, 0.05 * h), 0.0));
    body = min(body, min(shoulders, neck));
    float wave = sin(seed * 9.0 + jump * 30.0) * 0.08;
    float2 sh = float2(0.12 * h, 0.45 * h);
    float2 hand = mix(float2(0.20 * h, 0.05 * h), float2(0.28 * h + wave * h, 1.05 * h), hands);
    float arms = segDist(float2(abs(p.x), p.y), sh, hand) - 0.035 * h;
    return min(min(head, body), arms);
}

// ---------- LED wall content library
float3 wallContent(float2 c, float t, float tb, constant float *u, float hue) {
    int look = int(LOOK) % 6;
    float v = 0.0;
    float3 tint = palette(hue + c.x * 0.3 + c.y * 0.2, PALETTE);
    float2 cc = (c - 0.5) * float2(3.2, 1.0);
    if (look == 0) {            // mirrored spectrum + beat rings
        float x = abs(c.x - 0.5) * 2.0, bi = x * 5.0;
        float bv = bi < 1.0 ? SUB : bi < 2.0 ? BASS : bi < 3.0 ? LOWMID : bi < 4.0 ? MID : HIGH;
        float bars = step(c.y, bv * 0.95 + 0.03);
        float r = length(cc * float2(0.8, 1.0));
        float rings = smoothstep(0.1, 0.0, abs(fract(r * 3.0 - t * 0.5 - BEAT * 0.6) - 0.5) - 0.25 + 0.15 * BEAT);
        v = max(bars, rings * 0.6);
    } else if (look == 1) {     // tunnel rushing in with the tempo
        float r = length(cc), a = atan2(cc.y, cc.x);
        float z = 0.35 / max(r, 0.02) + tb * 0.5;
        v = step(0.5, fract(z)) * (0.5 + 0.5 * step(0.5, fract(a / (2.0 * PI) * 12.0 + tb * 0.125)));
        v *= smoothstep(0.0, 0.25, r);
        tint = palette(hue + z * 0.05, PALETTE);
    } else if (look == 2) {     // kaleido plasma
        float2 k = abs(cc); float a = atan2(k.y, k.x), r = length(k);
        a = abs(fmod(a, PI / 4.0) - PI / 8.0);
        float2 q = r * float2(cos(a), sin(a)) * 3.0;
        v = 0.5 + 0.5 * sin(q.x * 3.0 + t + BASS * 3.0) * cos(q.y * 3.0 - t * 0.7 + tb * 0.5);
        v = smoothstep(0.35, 0.9, v);
        tint = palette(hue + r * 0.4 + t * 0.05, PALETTE);
    } else if (look == 3) {     // checker grid flipping each beat
        float2 g = floor(c * float2(16.0, 5.0));
        v = fmod(g.x + g.y + floor(tb), 2.0) * (0.4 + 0.6 * BEAT);
        tint = (int(floor(tb / 4.0)) % 2 == 0) ? palette(hue, PALETTE) : float3(1.0);
    } else if (look == 4) {     // scrolling bars, speed = tempo
        float bar = fract(c.x * 8.0 - tb * 0.5);
        v = smoothstep(0.55, 0.5, abs(bar - 0.5) * 2.0) * step(abs(c.y - 0.5), 0.15 + 0.35 * (KICK * 0.5 + BEAT * 0.5));
        tint = palette(hue + floor(c.x * 8.0 - tb * 0.5) * 0.11, PALETTE);
    } else {                    // kick circle + radar sweep
        float r = length(cc);
        float circ = smoothstep(0.03, 0.0, abs(r - (0.15 + 0.3 * KICK)));
        float a = atan2(cc.y, cc.x);
        float sweep = pow(fract((a + tb * PI * 0.5) / (2.0 * PI)), 6.0) * smoothstep(0.5, 0.1, r);
        v = max(circ, sweep);
    }
    // build-up: wall flashes white, faster and faster (gated by BUILD, not a strobe)
    if (BUILD > 0.05) {
        float bl = step(0.5, fract(tb * mix(1.0, 4.0, BUILD)));
        v = mix(v, bl, BUILD * 0.7);
        tint = mix(tint, float3(1.0), BUILD * 0.6);
    }
    return tint * v;
}

fragment float4 fmain(VOut in [[stage_in]], constant float *u [[buffer(0)]]) {
    float aspect = RES_X / RES_Y;
    float2 uv = in.uv;
    float2 p = float2((uv.x * 2.0 - 1.0) * aspect, uv.y * 2.0 - 1.0);
    p += SHAKE * 0.012 * float2(sin(TIME * 91.0), cos(TIME * 77.0));
    float t = TIME, live = FADE, e = ENERGY;
    float tb = BEATIDX + PHASE;
    float3 col = float3(0.0);
    float hue = t * 0.03 + floor(BEATIDX / 16.0) * 0.17;

    // ---- LED wall
    float2 wallMin = float2(-1.25, -0.08), wallMax = float2(1.25, 0.62);
    if (p.x > wallMin.x && p.x < wallMax.x && p.y > wallMin.y && p.y < wallMax.y) {
        float2 w = (p - wallMin) / (wallMax - wallMin);
        float2 grid = float2(72, 22);
        float2 cell = floor(w * grid), f = fract(w * grid);
        float led = smoothstep(0.5, 0.25, length(f - 0.5));
        float2 c = (cell + 0.5) / grid;
        float idleW = 0.5 + 0.5 * sin(c.x * 6.0 + t * 0.6) * sin(c.y * 4.0 - t * 0.4);
        float3 content = mix(palette(hue + c.x * 0.3, PALETTE) * idleW * 0.35, wallContent(c, t, tb, u, hue), live);
        float pump = 0.45 + 0.55 * (0.5 * BEAT + 0.5 * KICK) * live;
        col += led * content * (0.3 + 1.1 * pump);
        col += 0.015 * palette(hue, PALETTE);
    }

    // ---- Truss
    float truss = 1.0 - smoothstep(0.0, 0.01, abs(p.y - 0.78) - 0.025);
    float lattice = step(0.5, fract((p.x + p.y) * 20.0)) * (1.0 - smoothstep(0.0, 0.004, abs(p.y - 0.78) - 0.02));
    col = mix(col, float3(0.06, 0.06, 0.07) + 0.04 * lattice, truss);

    // ---- Haze (thicker after pyro)
    float haze = (fbm(p * 1.6 + float2(t * 0.05, -t * 0.03)) * 0.8 + 0.2) * (1.0 + 0.6 * SMOKE);

    // ---- Moving heads (5 programs) + blinders
    const int NB = 8;
    int prog = int(BEAMPROG) % 5;
    for (int i = 0; i < NB; i++) {
        float fi = float(i), side = (i % 2 == 0) ? 1.0 : -1.0;
        float2 o = float2(-1.4 + 2.8 * (fi + 0.5) / float(NB), 0.76);
        float ang = -PI / 2.0, wid = 0.11, on;
        float alt = (i % 2 == int(BEATIDX) % 2) ? BEAT : KICK * 0.7;
        if (prog == 0) {        // slow sweep
            ang += sin(t * (0.35 + 0.15 * e) + fi * 0.9) * (0.35 + 0.35 * e);
            on = 0.35 + 0.9 * alt;
        } else if (prog == 1) { // fan opens/closes every 2 beats
            ang += (fi - 3.5) * (0.04 + 0.13 * abs(sin(PI * tb / 2.0)));
            wid = 0.05; on = 0.5 + 0.8 * BEAT;
        } else if (prog == 2) { // crossfire pairs
            ang += side * 0.5 * sin(PI * tb / 4.0);
            on = 0.45 + 0.8 * alt;
        } else if (prog == 3) { // ballyhoo chaos
            ang += 0.65 * sin(t * 2.3 + fi * 1.7) * sin(t * 1.1 + fi) + 0.2 * sin(tb * PI);
            on = 0.4 + 0.9 * KICK;
        } else {                // white chase curtain, straight down
            ang += 0.04 * (fi - 3.5);
            wid = 0.035;
            on = ((int(floor(tb * 2.0)) % NB == i) ? 1.0 : 0.12) + 0.5 * BEAT;
        }
        ang = mix(ang, atan2(-0.9 - o.y, 0.0 - o.x), BUILD * 0.8);   // build-up: converge centre stage
        on = mix(0.18, on + 0.4 * MID, live);
        float2 dir = float2(cos(ang), sin(ang));
        float2 rel = p - o;
        float along = dot(rel, dir);
        float across = abs(rel.x * dir.y - rel.y * dir.x);
        float width = 0.012 + along * wid;
        float beam = along > 0.0 ? exp(-pow(across / width, 2.0)) * exp(-along * 0.55) : 0.0;
        float3 bc = prog == 4 ? float3(1.0, 0.97, 0.9) : palette(hue + fi * 0.08 + 0.15, PALETTE);
        col += beam * on * bc * haze * 0.8;
        col += bc * on * 0.004 / (length(rel) + 0.01);
        float2 bo = o + float2(0.175, -0.035);
        float bd = length(p - bo);
        col += float3(1.0, 0.82, 0.55) * BLINDER * (smoothstep(0.03, 0.0, bd) * 3.0 + 0.02 / (bd + 0.02));
    }

    // ---- Lasers (5 programs)
    float L = LASER * live;
    if (L > 0.01) {
        int lp = int(LASERPROG) % 5;
        int lci = int(floor(BEATIDX / 8.0)) % 3;
        float3 lc = lci == 0 ? float3(0.1, 1.0, 0.25) : lci == 1 ? float3(1.0, 0.08, 0.2) : float3(0.25, 0.4, 1.0);
        float las = 0.0;
        if (lp == 0) {          // spinning fan from centre
            float2 rel = p - float2(0.0, 0.70);
            float a = atan2(rel.y, rel.x);
            float k = fract((a + t * 0.6 + BEATIDX * 0.39) / (2.0 * PI) * 14.0);
            las = exp(-abs(k - 0.5) * 900.0 / (1.0 + length(rel) * 2.0)) * smoothstep(0.0, 0.05, length(rel)) * exp(-length(rel) * 0.6) * step(rel.y, 0.0);
        } else if (lp == 1) {   // liquid sky sheet over the crowd
            float ys = 0.05 + 0.06 * sin(t * 0.4) + 0.03 * (fbm(float2(p.x * 2.0 + t * 0.3, t * 0.2)) - 0.5);
            float d = p.y - ys;
            las = exp(-abs(d) * 220.0) * 1.6 + (d < 0.0 ? exp(d * 5.0) * 0.12 * haze * (0.6 + 0.4 * fbm(p * 6.0 + t)) : 0.0);
            las *= 0.7 + 0.3 * BEAT;
        } else if (lp == 2) {   // crisscross from the wings
            for (int s = -1; s <= 1; s += 2) {
                float2 o = float2(1.25 * float(s), 0.0);
                for (int k = 0; k < 5; k++) {
                    float a = (s < 0 ? 0.0 : PI) - float(s) * (-0.35 + 0.17 * float(k) + 0.25 * sin(PI * tb / 4.0 + float(k)));
                    las += ray(p, o, float2(cos(a), sin(a)), 0.0016, 3.0);
                }
            }
        } else if (lp == 3) {   // tunnel / cone + ring riding the beat
            float2 rel = p - float2(0.0, 0.32);
            float a = atan2(rel.y, rel.x), r = length(rel);
            float k = fract((a + t * 0.25) / (2.0 * PI) * 28.0);
            float spokes = exp(-abs(k - 0.5) * 600.0 / (1.0 + r * 3.0)) * smoothstep(0.02, 0.3, r) * exp(-r * 0.4);
            float ring = exp(-abs(r - (0.2 + 1.2 * PHASE)) * 160.0) * (1.0 - PHASE);
            las = spokes * 0.8 + ring;
        } else {                // scanning vertical grid from the truss
            for (int k = 0; k < 7; k++) {
                float x0 = -1.2 + 0.4 * float(k) + 0.25 * sin(PI * tb / 2.0 + float(k) * 0.7);
                float a = -PI / 2.0 + 0.25 * sin(PI * tb / 8.0 + float(k));
                las += ray(p, float2(x0, 0.74), float2(cos(a), sin(a)), 0.0015, 2.2);
            }
        }
        col += lc * las * L * (0.6 + 0.8 * haze) * 1.3;
    }

    // ---- Pyro: flame jets
    if (FIRE > 0.01) {
        for (int j = 0; j < 4; j++) {
            if (((int(JETMASK) >> j) & 1) == 0) continue;
            float jx = j == 0 ? -1.05 : j == 1 ? -0.55 : j == 2 ? 0.55 : 1.05;
            float2 fp = p - float2(jx, -0.08);
            float hgt = 0.8 * sqrt(FIRE);
            if (fp.y > -0.02 && fp.y < hgt * 1.4) {
                float yy = fp.y / max(hgt, 0.01);
                float n = fbm(float2(fp.x * 9.0 + float(j) * 7.0, fp.y * 5.0 - t * 7.0));
                float wdt = 0.06 + 0.09 * yy;
                float flame = smoothstep(wdt, 0.0, abs(fp.x + (n - 0.5) * 0.09 * yy)) * smoothstep(1.25, 0.15, yy + (n - 0.5) * 0.7);
                float core = smoothstep(0.025, 0.0, abs(fp.x)) * smoothstep(0.7, 0.0, yy);
                float3 fc = mix(float3(1.0, 0.9, 0.55), float3(1.0, 0.28, 0.03), clamp(yy * 1.2, 0.0, 1.0));
                // flames occlude what's behind them (mix), then add a hot core
                col = mix(col, fc * 1.3, clamp(flame * FIRE * 1.2, 0.0, 1.0));
                col += float3(1.0, 0.9, 0.6) * core * FIRE * 0.8;
            }
            col += float3(1.0, 0.45, 0.12) * 0.035 * FIRE / (length(fp - float2(0, 0.25)) + 0.06);
        }
    }
    // ---- Pyro: fireballs
    if (FIREBALL < 0.999) {
        float f = FIREBALL;
        for (int s = -1; s <= 1; s += 2) {
            float2 d = p - float2(0.8 * float(s), 0.05 + f * 0.45);
            float r = 0.08 + 0.42 * sqrt(f);
            float n = fbm(d * 5.0 + float2(0.0, -t * 2.0) + float(s) * 3.0);
            float rr = length(d) + (n - 0.5) * 0.35 * r;
            float ball = smoothstep(r, r * 0.5, rr);
            // hot yellow core -> orange body -> dark smoky edge, cooling as it rises
            float inner = smoothstep(r * 0.75, 0.0, rr);
            float3 fc = mix(float3(0.95, 0.35, 0.04), float3(1.0, 0.8, 0.35), inner * (1.0 - f));
            fc *= 0.6 + 0.8 * n;
            float heat = pow(1.0 - f, 1.3);
            col = mix(col, fc * (0.4 + 1.1 * heat), clamp(ball * (0.3 + heat), 0.0, 1.0));
            col = mix(col, float3(0.03, 0.025, 0.025), ball * smoothstep(0.5, 1.0, f) * 0.7);
        }
    }
    // ---- Pyro: spark fountains (gerbs)
    if (SPARKS > 0.01) {
        for (int g = 0; g < 4; g++) {
            float gx = g == 0 ? -0.85 : g == 1 ? -0.3 : g == 2 ? 0.3 : 0.85;
            if (abs(p.x - gx) > 0.6 || p.y < -0.12 || p.y > 0.85) continue;
            float2 o = float2(gx, -0.08);
            for (int k = 0; k < 28; k++) {
                float h1 = hash11(float(k) * 3.1 + float(g) * 17.0), h2 = hash11(float(k) * 7.7 + float(g) * 5.0);
                float life = 1.1;
                float age = fract(t / life + h1) * life;
                float2 v = float2((h2 - 0.5) * 0.55, 1.15 + 0.35 * h1);
                float2 sp = o + v * age + float2(0.0, -0.9) * age * age;
                float d = length(p - sp);
                col += float3(1.0, 0.75, 0.35) * SPARKS * (1.0 - age / life) * (0.00012 / (d * d + 0.00004));
            }
        }
    }
    // ---- CO2 cannons
    if (CO2 > 0.01) {
        for (int c = 0; c < 4; c++) {
            float cx = c == 0 ? -0.75 : c == 1 ? -0.2 : c == 2 ? 0.2 : 0.75;
            float2 q = p - float2(cx, -0.08);
            if (q.y < 0.0 || q.y > 1.0) continue;
            float wdt = 0.018 + q.y * 0.12;
            float n = fbm(float2(q.x * 6.0, q.y * 4.0 - t * 5.0) + float(c));
            float plume = smoothstep(wdt, wdt * 0.2, abs(q.x) + (n - 0.5) * 0.08) * smoothstep(1.0 * CO2 + 0.15, 0.0, q.y) * (0.55 + 0.45 * n);
            col = mix(col, float3(0.85, 0.88, 0.95) + col * 0.3, clamp(plume * CO2 * 0.9, 0.0, 0.95));
        }
    }

    // ---- Stage deck
    if (p.y < -0.08 && p.y > -0.28) {
        float3 deck = float3(0.02);
        deck += 0.18 * (0.3 + 0.7 * BEAT * live) * palette(hue + p.x * 0.2, PALETTE) * smoothstep(-0.28, -0.08, p.y);
        float edge = 1.0 - smoothstep(0.0, 0.008, abs(p.y + 0.08));
        float chase = step(0.5, fract(p.x * 6.0 - tb));
        deck += edge * palette(hue + 0.5 + p.x * 0.1, PALETTE) * (0.3 + 0.7 * mix(KICK, chase, 0.5) * live);
        deck += float3(1.0, 0.5, 0.15) * FIRE * 0.15;
        col = deck + col * 0.12;
    }

    // ---- Crowd silhouettes (rim light picks up fire and blinders)
    float3 rim = palette(hue + 0.25, PALETTE) * (0.25 + 0.75 * live * (0.4 + 0.6 * BEAT));
    rim += float3(1.0, 0.5, 0.15) * (FIRE * 0.8 + (1.0 - FIREBALL) * 0.8) + float3(1.0, 0.85, 0.6) * BLINDER;
    const int ROWS = 6;
    for (int r = 0; r < ROWS; r++) {
        float fr = float(r) / float(ROWS - 1);
        float scale = mix(0.24, 0.62, fr);
        float baseY = mix(-0.36, -1.28, fr);
        float spacing = 0.21 * scale;
        float2 q = float2(p.x / scale, (p.y - baseY) / scale);
        float idx = floor(q.x / (spacing / scale) + 0.5);
        float dmin = 1e5, dup = 1e5;
        float2 qu = q + float2(0.0, 0.018 / scale);   // probe slightly above: rim only on top edges (back-lit)
        for (int j = -1; j <= 1; j++) {
            float id = idx + float(j);
            float seed = hash11(id * 13.7 + float(r) * 71.3);
            if (seed > mix(0.15, 1.0, DENSITY)) continue;
            float cx = id * (spacing / scale) + (seed - 0.5) * 0.12;
            float hgt = 0.85 + 0.25 * hash11(seed * 91.0);
            float hop = JUMP * abs(sin(PI * (PHASE + seed * 0.18))) * 0.12 * (0.6 + 0.8 * seed);
            float sway = (1.0 - JUMP) * 0.03 * sin(t * 1.3 + seed * 6.0);
            float hands = clamp(HANDS * (0.6 + 0.8 * seed) - 0.1, 0.0, 1.0);
            dmin = min(dmin, person(q - float2(cx + sway, 0.0), hgt, hop, hands, seed));
            dup = min(dup, person(qu - float2(cx + sway, 0.0), hgt, hop, hands, seed));
        }
        float d = dmin * scale;
        float cover = 1.0 - smoothstep(0.0, 0.003, d);
        float above = 1.0 - smoothstep(0.0, 0.003, dup * scale);
        float edge = cover * (1.0 - above);
        col = mix(col, float3(0.008, 0.008, 0.012) + rim * edge * mix(0.9, 0.35, fr), cover);
    }

    // ---- Strobe + blinder wash (both rate-limited on the CPU)
    col += float3(1.0) * STROBE * 1.8;
    col += float3(1.0, 0.9, 0.75) * BLINDER * BLINDER * 0.25;

    // ---- Post
    col *= mix(0.45, 1.0, live);
    col = 1.0 - exp(-col * 1.7);
    col *= smoothstep(1.9, 0.6, length(p * float2(0.8, 1.0)));
    col += (hash21(uv * RES_X + t) - 0.5) * 0.015;
    col *= (1.0 - BLACKOUT);
    return float4(col, 1.0);
}
"""#
