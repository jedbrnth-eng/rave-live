# Smoothness: how it's measured and what the limits are

Jed's brief for 0.5: some visuals flashed and moved too quickly, and some transitions glitched. Everything must be
smooth and still on the beat. This page explains the measuring tool, the limits it checks, and what changed.

## The probe

`--smoothlog <file>` (test only) adds a small pass after each finished frame (after Syphon / brightness, exactly what
the audience sees). The frame is box-filtered on the GPU to a 64 x 36 grid of luma values and copied into a shared
buffer. The comparison with the previous frame runs on a background queue when the GPU is done, so the render loop
never waits (A/B on the same preset: 60.5 fps without, 59.4 with, within run-to-run noise). One line per frame:

| column | meaning |
|---|---|
| `luma` | mean luma 0..1 |
| `dmean` | change of the mean since the last frame: a whole-frame flash or blackout |
| `flick` | mean absolute per-cell change |
| `resid` | per-block change left after the best +-2 cell shift (8 x 6-cell blocks): change that motion doesn't explain (pops, flashes, wrong frames) |
| `motion` | mean best shift per block, in cells per frame (1 cell = 1/64 of the width) |
| `phase`, `beat`, `locked`, `kick`, `drop`, `build` | the beat grid and show state the frame was drawn with |
| `mode`, `scene`, `preset`, `trans` | what was on screen, and the SHOW transition type/progress |

`scripts/smooth_report.py LOG...` turns logs into per-preset and per-transition tables (`--json` for the full data).
Per-frame changes are scaled to a 60 Hz frame (a 28 ms frame on a busy GPU shows more change for the same motion).

## The limits

| limit | value | where it comes from |
|---|---|---|
| jump: `resid` above | 0.060 | about twice the p99 of the presets Jed likes as calm-but-alive (the calmed Hyperdrive 0.022-0.027, Neon City 0.024-0.031, Terrain 0.014-0.020, Ink Water 0.007): a frame above it is a visible pop |
| jump: `dmean` above | 0.035 | a 3.5 % whole-frame brightness step in one frame (about 9 grey levels). Those presets have none off the beat |
| beat window | 0.08 beat before to 0.18 after the beat | beat accents belong there: eased attacks start ~35 ms early so they peak ON the beat, and detected (not predicted) kicks peak 60-80 ms late; at 128 BPM the window is -37..+84 ms |
| drop grace | 1 s after a drop | the drop hit is meant to hit |
| target | <= 8 jumps per minute per look | one pop every 7-8 s at most, outside the beat window, on the demo's groove + build + drop |
| transition glitch: one frame with `dmean` > 0.10 or `resid` > 0.12 | 0 per transition | a 4-beat blend at 72 fps moves < 0.01 per frame; a one-frame black/white flash, stale frame or size pop is 0.1-0.5 |

A jump is counted once per pop (a run of consecutive over-limit frames is one jump), so easing a flash over three
frames doesn't make it look worse than a one-frame flash. The flash itself is not a target: the probe never forbids
reacting, only off-beat, un-eased steps.

**Beat lock.** The same log gives luma by beat phase (8 bins, like `--lumlog`): contrast = (max - min) / mean. After
any change the peak must stay in the first bins (on or just after the beat) and the contrast must not collapse.

## Causes found and fixed

1. **The musical beat counter jumped.** The analyzer's bar estimate flips between two guesses on four-on-the-floor
   music; the renderer's beat counter followed it, so it went 1, 4, 5, 6, 7, 4, 5, 8... (+-2..3 beats about every
   beat on the demo). Everything that moves with the beat clock (Wormhole and Laser Grid travel, Terrain ridges, Stage
   patterns, Vinyl, Life) lurched every time. `BeatCounter` now advances by exactly one per beat and only adopts a new
   bar alignment once the analyzer agrees on it for 8 beats, or on a drop (where the cut hides it). The continuous
   beat clock never jumps; it free-runs at 120 BPM without a lock and keeps going from where it was when the lock comes
   back.
2. **One-frame attacks.** Kick, snare and hat envelopes jumped to full in one frame; the beat pulse was a saw-tooth.
   Now every hit eases in (`Pulse`: 10-90 % rise ~40 ms on Normal, release ~160 ms), the beat pulse starts 35 ms early
   and peaks on the beat, and the predicted kick fires 40 ms early so its eased peak lands on the beat too. Wild keeps
   shorter times (punchier).
3. **Noisy band levels.** Band energies and loudness go through critically damped filters (no overshoot, ~90 ms rise
   for bands), the spectrum through a 12 ms attack / 140 ms release. Visuals react as much, minus the frame-to-frame
   jitter that made full-screen fields (Plasma, Nebula, Northern Lights) shimmer.
4. **Stage build-up strobe.** The LED wall flashed a hard square wave whose rate slid with the build amount, up to
   8.5 flashes/s and off the grid, outside the strobe limiter. It is now a soft cosine pulse on the beat, once per beat
   (2.1/s at 128 BPM), twice per beat only late in a build on Wild. The camera shake is ~5 Hz instead of ~14 Hz and
   gentler on Normal.
5. **Strobe on Normal.** Still limited to 3 flashes/s by the same limiter, but each flash eases in and out (70 % peak)
   instead of a 45 ms full-white frame. Wild keeps the hard strobe.
6. **MilkDrop.** projectM's beat sensitivity went up to 3.5 during builds (presets spasmed); it is now 0.8-1.3 on Normal
   (Wild up to 1.9). projectM rendered a frame for every display frame, so presets ran at double speed on 120 Hz
   screens; it now renders at most ~75 frames/s. On Normal and Chill each shown frame eases 60 % (45 %; Wild 75 %) toward the new
   projectM frame, which turns a preset's one-frame flicker into a quick fade. projectM's own hard cuts stay off; only
   the director cuts, on drops.
7. **Single presets.** Wormhole's rings shimmered where they get denser than a pixel; Crystals, Nebula and Plasma
   pumped the whole screen on every kick or bass wobble. Their reactions are now on the parts that should move.

## Transitions

- SHOW picks the next scene a bar early and renders it offscreen for that bar, so it starts warm: no empty or stale
  first frames, MilkDrop presets are loaded and running. During a build the drop scene is prepared the same way.
- Transition progress is monotonic: it follows the beat clock, but a clock re-alignment or a lost lock can no longer
  make it jump forward or back.
- A scene can't transition into itself (a Classic -> Classic transition rendered the same renderer twice per frame).
- Classic feedback textures are cleared when a preset starts (no frame of an earlier preset or visit), and Classic mode
  crossfades between presets (both keep running for the blend, in two feedback slots) instead of cutting.
- The drop cut is one clean cut on the drop; its white bloom eases out and is smaller on Normal (0.55) and Chill (0.3).

## Results

Filled in from the final sweep (`evidence/` is not committed; numbers are from `--demo`, 1280 x 720, three instances
sharing the GPU).
