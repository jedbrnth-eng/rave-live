// Feedback Tunnel: each frame zooms and turns the previous frame, then draws the waveform on top -> an endless tunnel.
// SPDX-License-Identifier: CC0-1.0  (example shipped with RAVE LIVE)

float4 rave(Rave r) {
    float2 q = rotate(r.p, 0.01 + 0.02 * r.bass) * (0.97 - 0.02 * r.kick);   // where this pixel was last frame
    float2 quv = float2(q.x / r.aspect * 0.5 + 0.5, q.y * 0.5 + 0.5);
    float3 old = previous(r, quv).rgb * 0.94;                                  // fade a little every frame
    float x = r.uv.x;
    float w = waveform(r, x) * 0.3;                                            // the waveform as a line across the middle
    float line = exp(-abs(r.p.y - w) * 80.0);
    float3 col = old + palette(r.hue + x * 0.5) * line * (0.4 + beatPulse(r, 6.0));
    return float4(min(col, float3(2.0)), 1.0);
}
