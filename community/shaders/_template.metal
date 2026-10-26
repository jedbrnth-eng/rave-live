// RAVE LIVE Shader Lab starter. Copy this file, rename it (no leading "_"), and save: it shows up in Classic Visuals
// after the built-in presets (press ] to step to it). Every save reloads it. Guide: docs/SHADERS.md
// SPDX-License-Identifier: GPL-3.0-or-later  (the licence for shaders sent to community/; see community/README.md)

float4 rave(Rave r) {
    float2 p = r.p;                                   // centred coordinates, y up
    float d = abs(length(p) - 0.4 - 0.2 * r.kick);    // distance to a ring that kicks outward on the bass drum
    float3 color = palette(r.hue + r.beat * 0.05);    // colour slowly cycles with the beat clock
    float glow = exp(-d * 30.0) * (0.4 + beatPulse(r, 6.0));
    return float4(color * glow, 1.0);
}
