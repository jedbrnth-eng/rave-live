// Pointer Paint: drag the mouse (or move your hands with the camera on) to paint glowing ink that slowly drifts and fades.
// The beat drops a dot of ink by itself so the canvas is never empty.
// SPDX-License-Identifier: CC0-1.0  (example shipped with RAVE LIVE)

float4 rave(Rave r) {
    float2 drift = float2(sin(r.p.y * 3.0 + r.time * 0.4), cos(r.p.x * 3.0 - r.time * 0.3)) * 0.002;
    float2 q = r.p - drift;
    float3 col = previous(r, float2(q.x / r.aspect * 0.5 + 0.5, q.y * 0.5 + 0.5)).rgb * 0.985;
    for (int i = 0; i < r.pointerCount; i++) {
        float3 pt = r.pointer[i];                                   // x, y, strength
        float d = length(r.p - pt.xy);
        col += palette(r.hue + r.time * 0.05 + float(i) * 0.3) * exp(-d * 60.0) * pt.z * 0.25;
    }
    float b = floor(r.beat);                                       // one ink drop per beat, somewhere new
    float2 spot = (float2(hash(float2(b, 1.0)), hash(float2(b, 2.0))) - 0.5) * float2(1.6 * r.aspect, 1.6);
    col += palette(r.hue + hash(float2(b, 3.0))) * exp(-length(r.p - spot) * 40.0) * beatPulse(r, 8.0) * 0.4;
    return float4(min(col, float3(3.0)), 1.0);
}
