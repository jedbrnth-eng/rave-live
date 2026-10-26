// Spectrum Bloom: a flower whose petals are the live spectrum (bass at the centre line, treble at the tips).
// SPDX-License-Identifier: CC0-1.0  (example shipped with RAVE LIVE)

float4 rave(Rave r) {
    float2 p = rotate(r.p, r.beat * 0.03);
    float a = atan2(p.y, p.x), rad = length(p);
    float petals = 6.0 + floor(r.variation * 4.0) * 2.0;
    float x = abs(fract(a / (2.0 * PI) * petals) - 0.5) * 2.0;   // 0 at the petal middle, 1 at its edge
    float level = spectrum(r, x);                                 // that slice of the spectrum
    float edge = 0.25 + 0.6 * level;
    float inside = smoothstep(edge, edge - 0.02, rad);
    float3 col = palette(r.hue + x * 0.4 + rad * 0.3) * inside * (0.35 + 0.65 * rad / edge);
    col += float3(1.0) * exp(-abs(rad - edge) * 120.0) * 0.5;     // bright rim
    col *= 0.8 + 0.4 * beatPulse(r, 5.0);
    return float4(col, 1.0);
}
