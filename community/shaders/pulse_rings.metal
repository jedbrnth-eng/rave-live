// Pulse Rings: one ring leaves the centre on every beat; the downbeat ring is brighter.
// SPDX-License-Identifier: CC0-1.0  (example shipped with RAVE LIVE)

float4 rave(Rave r) {
    float rad = length(r.p);
    float3 col = float3(0.0);
    for (int i = 0; i < 6; i++) {                      // the last 6 beats' rings, still travelling outward
        float age = r.beatPhase + float(i);            // beats since that ring left
        float ringR = age * 0.35;
        float bright = exp(-age * 0.6);
        float downbeat = (fmod(floor(r.beat) - float(i), 4.0) == 0.0) ? 1.8 : 1.0;
        col += palette(r.hue + float(i) * 0.08) * exp(-abs(rad - ringR) * 45.0) * bright * downbeat;
    }
    col += palette(r.hue + 0.5) * exp(-rad * 8.0) * (0.3 + r.kick);
    return float4(col, 1.0);
}
