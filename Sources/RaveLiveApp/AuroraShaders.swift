// AURORA mode: GPU stable-fluid simulation + ~1M particles + bloom, driven by the beat and by your
// hands/body through the Mac camera (Vision). Fluid solver structure follows Pavel Dobryakov's
// WebGL-Fluid-Simulation (MIT): advect -> splat -> curl/vorticity -> divergence -> pressure -> gradient.
let auroraShaderSource = #"""
#include <metal_stdlib>
using namespace metal;
constexpr sampler lin(address::clamp_to_edge, filter::linear);

struct Splat { float2 pos; float2 force; float4 color; float radius; float p1; float p2; float p3; };   // 48 bytes
struct Particle { float2 pos; float2 vel; float life; float maxLife; float hue; float seed; };
struct PU {                 // particle uniforms
    float dt; float time; float energy; float kick;
    float hue; float noise; float drop; float maskOn;
    float2 simTexel; float2 res;
    float4 emit[8];         // xy = position (uv), z = radius, w = weight (0 = off)
    uint emitCount; uint count; float speedGain; float size;
};

float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}
float2 curlNoise(float2 p) {
    const float e = 0.01;
    float n1 = vnoise(p + float2(0, e)), n2 = vnoise(p - float2(0, e));
    float n3 = vnoise(p + float2(e, 0)), n4 = vnoise(p - float2(e, 0));
    return float2(n1 - n2, -(n3 - n4)) / (2.0 * e);
}
float3 pal(float t) { return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67))); }

uint2 clampI(int2 g, int2 sz) { return uint2(clamp(g, int2(0), sz - 1)); }

// ---------------- fluid
kernel void advect(texture2d<float, access::sample> vel [[texture(0)]],
                   texture2d<float, access::sample> src [[texture(1)]],
                   texture2d<float, access::write> dst [[texture(2)]],
                   constant float4 &P [[buffer(0)]],          // x dt, y dissipation, zw sim texel size
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float2 v = vel.sample(lin, uv).xy;
    float2 back = uv - P.x * v * P.zw;
    float4 r = src.sample(lin, back) / (1.0 + P.y * P.x);
    dst.write(r, gid);
}

kernel void splat(texture2d<float, access::read> src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant Splat *s [[buffer(0)]], constant uint &n [[buffer(1)]],
                  constant float2 &am [[buffer(2)]],          // x aspect, y mode (0 velocity, 1 dye)
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float4 c = src.read(gid);
    for (uint i = 0; i < n; i++) {
        float2 d = uv - s[i].pos; d.x *= am.x;
        float g = exp(-dot(d, d) / s[i].radius);
        if (am.y < 0.5) c.xy += s[i].force * g; else c.rgb += s[i].color.rgb * g;
    }
    dst.write(c, gid);
}

// body silhouette from the camera: pushes fluid out of your outline and paints glowing edges
kernel void maskInject(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       texture2d<float, access::sample> mask [[texture(2)]],
                       constant float4 &M [[buffer(0)]],      // x mode(0 vel,1 dye), y strength, z hue, w time
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 sz = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / sz;
    float2 e = float2(1.5 / 256.0, 1.5 / 144.0);
    float m = mask.sample(lin, uv).r;
    float gx = mask.sample(lin, uv + float2(e.x, 0)).r - mask.sample(lin, uv - float2(e.x, 0)).r;
    float gy = mask.sample(lin, uv + float2(0, e.y)).r - mask.sample(lin, uv - float2(0, e.y)).r;
    float2 grad = float2(gx, gy);
    float edge = clamp(length(grad) * 2.0, 0.0, 1.0);
    float4 c = src.read(gid);
    if (M.x < 0.5) {
        c.xy -= grad * M.y;                                   // outward (gradient points inward)
        c.xy *= 1.0 - 0.6 * m;                                // body is a soft obstacle
    } else {
        float3 col = pal(M.z + uv.y * 0.3 + M.w * 0.05);
        c.rgb += col * edge * M.y;
        c.rgb *= 1.0 - 0.25 * m;
    }
    dst.write(c, gid);
}

kernel void curlK(texture2d<float, access::read> vel [[texture(0)]], texture2d<float, access::write> outc [[texture(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    int2 sz = int2(vel.get_width(), vel.get_height()); int2 g = int2(gid);
    if (g.x >= sz.x || g.y >= sz.y) return;
    float L = vel.read(clampI(g + int2(-1, 0), sz)).y, R = vel.read(clampI(g + int2(1, 0), sz)).y;
    float B = vel.read(clampI(g + int2(0, -1), sz)).x, T = vel.read(clampI(g + int2(0, 1), sz)).x;
    outc.write(float4(0.5 * (R - L - T + B), 0, 0, 0), gid);
}

kernel void vorticity(texture2d<float, access::read> vel [[texture(0)]], texture2d<float, access::read> curl [[texture(1)]],
                      texture2d<float, access::write> dst [[texture(2)]], constant float2 &P [[buffer(0)]],   // dt, strength
                      uint2 gid [[thread_position_in_grid]]) {
    int2 sz = int2(vel.get_width(), vel.get_height()); int2 g = int2(gid);
    if (g.x >= sz.x || g.y >= sz.y) return;
    float L = curl.read(clampI(g + int2(-1, 0), sz)).x, R = curl.read(clampI(g + int2(1, 0), sz)).x;
    float B = curl.read(clampI(g + int2(0, -1), sz)).x, T = curl.read(clampI(g + int2(0, 1), sz)).x;
    float C = curl.read(gid).x;
    float2 f = 0.5 * float2(abs(T) - abs(B), abs(R) - abs(L));
    f /= length(f) + 0.0001;
    f *= P.y * C; f.y *= -1.0;
    float2 v = vel.read(gid).xy + f * P.x;
    dst.write(float4(clamp(v, -1000.0, 1000.0), 0, 0), gid);
}

kernel void divergence(texture2d<float, access::read> vel [[texture(0)]], texture2d<float, access::write> dv [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 sz = int2(vel.get_width(), vel.get_height()); int2 g = int2(gid);
    if (g.x >= sz.x || g.y >= sz.y) return;
    float2 C = vel.read(gid).xy;
    float L = g.x > 0 ? vel.read(uint2(g + int2(-1, 0))).x : -C.x;
    float R = g.x < sz.x - 1 ? vel.read(uint2(g + int2(1, 0))).x : -C.x;
    float B = g.y > 0 ? vel.read(uint2(g + int2(0, -1))).y : -C.y;
    float T = g.y < sz.y - 1 ? vel.read(uint2(g + int2(0, 1))).y : -C.y;
    dv.write(float4(0.5 * (R - L + T - B), 0, 0, 0), gid);
}

kernel void pressureK(texture2d<float, access::read> p [[texture(0)]], texture2d<float, access::read> dv [[texture(1)]],
                      texture2d<float, access::write> dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    int2 sz = int2(p.get_width(), p.get_height()); int2 g = int2(gid);
    if (g.x >= sz.x || g.y >= sz.y) return;
    float L = p.read(clampI(g + int2(-1, 0), sz)).x, R = p.read(clampI(g + int2(1, 0), sz)).x;
    float B = p.read(clampI(g + int2(0, -1), sz)).x, T = p.read(clampI(g + int2(0, 1), sz)).x;
    dst.write(float4((L + R + B + T - dv.read(gid).x) * 0.25, 0, 0, 0), gid);
}

kernel void scaleK(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                   constant float &k [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(src.read(gid) * k, gid);
}

kernel void gradient(texture2d<float, access::read> p [[texture(0)]], texture2d<float, access::read> vel [[texture(1)]],
                     texture2d<float, access::write> dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    int2 sz = int2(p.get_width(), p.get_height()); int2 g = int2(gid);
    if (g.x >= sz.x || g.y >= sz.y) return;
    float L = p.read(clampI(g + int2(-1, 0), sz)).x, R = p.read(clampI(g + int2(1, 0), sz)).x;
    float B = p.read(clampI(g + int2(0, -1), sz)).x, T = p.read(clampI(g + int2(0, 1), sz)).x;
    float2 v = vel.read(gid).xy - float2(R - L, T - B);
    dst.write(float4(v, 0, 0), gid);
}

// ---------------- particles
kernel void particles(device Particle *ps [[buffer(0)]], constant PU &U [[buffer(1)]],
                      texture2d<float, access::sample> vel [[texture(0)]],
                      texture2d<float, access::sample> mask [[texture(1)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= U.count) return;
    Particle p = ps[id];
    float2 fv = vel.sample(lin, p.pos).xy * U.simTexel;                        // uv / s
    float2 cn = curlNoise(p.pos * float2(3.0 * U.res.x / U.res.y, 3.0) + U.time * 0.05 + p.seed) * U.noise;
    float2 target = fv * U.speedGain + cn * 0.02;
    p.vel = mix(p.vel, target, 0.2);
    p.pos += p.vel * U.dt;
    p.life -= U.dt;
    bool out = p.pos.x < -0.02 || p.pos.x > 1.02 || p.pos.y < -0.02 || p.pos.y > 1.02;
    if (p.life <= 0.0 || out) {
        float r1 = hash11(p.seed * 91.7 + U.time * 13.1), r2 = hash11(p.seed * 17.3 + U.time * 7.7), r3 = hash11(p.seed * 3.3 + U.time);
        float2 pos = float2(r1, r2);
        float hue = U.hue + r3 * 0.25;
        // pick an emitter (hands, beat ring) for some particles; the rest spawn everywhere
        if (U.emitCount > 0 && r3 < 0.55) {
            uint k = uint(r3 / 0.55 * float(U.emitCount)) % U.emitCount;
            float4 em = U.emit[k];
            if (em.w > 0.0) {
                float a = r1 * 6.28318, rr = sqrt(r2) * em.z;
                pos = em.xy + float2(cos(a) * rr * U.res.y / U.res.x, sin(a) * rr);
                hue = U.hue + 0.15 * float(k) + r1 * 0.1;
            }
        }
        // body: spawn along the silhouette
        if (U.maskOn > 0.5 && r3 > 0.6) {
            for (int t = 0; t < 6; t++) {
                float2 c = float2(hash11(p.seed + float(t) * 1.7 + U.time), hash11(p.seed * 2.1 + float(t) + U.time * 1.3));
                float m = mask.sample(lin, c).r;
                if (m > 0.3 && m < 0.9) { pos = c; hue = U.hue + 0.5; break; }
            }
        }
        p.pos = pos; p.vel = float2(0.0);
        p.maxLife = 2.0 + 4.0 * hash11(p.seed * 5.1 + U.time);
        p.life = p.maxLife; p.hue = hue;
    }
    ps[id] = p;
}

struct PV { float4 pos [[position]]; float size [[point_size]]; float4 col; };
vertex PV pvert(uint vid [[vertex_id]], const device Particle *ps [[buffer(0)]], constant PU &U [[buffer(1)]]) {
    Particle p = ps[vid];
    PV o;
    o.pos = float4(p.pos.x * 2.0 - 1.0, 1.0 - p.pos.y * 2.0, 0, 1);
    float speed = length(p.vel) * 6.0;
    float fade = smoothstep(0.0, 0.4, p.life) * smoothstep(p.maxLife, p.maxLife - 0.3, p.life);
    float3 c = mix(pal(p.hue), float3(1.0), clamp(speed * 0.25 - 0.4, 0.0, 0.35));
    // 1M additive points: each one must be faint, density makes the light
    o.col = float4(c * fade * (0.004 + 0.05 * clamp(speed, 0.0, 2.0)) * (1.0 + U.kick * 0.6), 1.0);
    o.size = U.size * (0.7 + 0.4 * clamp(speed, 0.0, 1.5));
    return o;
}
fragment float4 pfrag(PV in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5);
    return in.col * smoothstep(0.5, 0.0, d);
}

// ---------------- display
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut fsv(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
}
fragment float4 dyeToHDR(VOut in [[stage_in]], texture2d<float> dye [[texture(0)]], constant float &gain [[buffer(0)]]) {
    float3 c = dye.sample(lin, in.uv).rgb;
    // soft shading from the dye gradient makes the smoke look volumetric
    float2 e = float2(1.0 / dye.get_width(), 1.0 / dye.get_height()) * 2.0;
    float l = length(dye.sample(lin, in.uv - float2(e.x, 0)).rgb), r = length(dye.sample(lin, in.uv + float2(e.x, 0)).rgb);
    float b = length(dye.sample(lin, in.uv - float2(0, e.y)).rgb), t = length(dye.sample(lin, in.uv + float2(0, e.y)).rgb);
    float3 n = normalize(float3(l - r, b - t, 0.35));
    float shade = clamp(dot(n, normalize(float3(-0.4, -0.5, 0.75))), 0.0, 1.0);
    c *= 0.45 + 0.7 * shade;
    return float4(c * gain, 1.0);
}
fragment float4 finalComp(VOut in [[stage_in]], texture2d<float> hdr [[texture(0)]], texture2d<float> bloomA [[texture(1)]],
                          texture2d<float> bloomB [[texture(2)]], constant float4 &F [[buffer(0)]],    // x bloom, y strobe, z blackout, w fade
                          constant float4 &G [[buffer(1)]]) {                                           // x symmetry: 0 none, 1 mirror, 2 quad, 3 kaleido6
    float2 uv = in.uv;
    int sym = int(G.x);
    if (sym == 1) uv.x = 0.5 - abs(uv.x - 0.5);
    else if (sym == 2) uv = 0.5 - abs(uv - 0.5);
    else if (sym == 3) {
        float2 c = (uv - 0.5) * float2(G.y, 1.0);
        float a = atan2(c.y, c.x), r = length(c), seg = 3.14159 / 3.0;
        a = abs(fmod(a + 20.0 * 3.14159, seg) - seg * 0.5);
        uv = float2(r * cos(a) / G.y, r * sin(a)) + 0.5;
    }
    // gentle chromatic aberration toward the edges
    float2 dc = (uv - 0.5) * 0.003;
    float3 c = float3(hdr.sample(lin, uv + dc).r, hdr.sample(lin, uv).g, hdr.sample(lin, uv - dc).b);
    float3 bA = max(bloomA.sample(lin, uv).rgb - 0.25, 0.0), bB = max(bloomB.sample(lin, uv).rgb - 0.15, 0.0);
    c += (bA * 0.5 + bB * 0.6) * F.x;
    c = c * (2.51 * c + 0.03) / (c * (2.43 * c + 0.59) + 0.14);                  // ACES-ish
    c *= mix(0.4, 1.0, F.w);
    c *= smoothstep(1.25, 0.35, length((uv - 0.5) * float2(1.2, 1.0)));
    c += F.y * 1.2;
    c *= 1.0 - F.z;
    c += (hash21(uv * 1931.0 + F.w) - 0.5) * 0.01;
    return float4(clamp(c, 0.0, 1.0), 1.0);
}
"""#
