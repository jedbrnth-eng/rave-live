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

From `--demo` (128 BPM: groove, snare-roll build, gap, drop), 1280 x 720, 46 s per look with three or four app
instances sharing the GPU, on an M4 Max; before = the 0.5 integration build with only the probe added, after = this
branch. Logs and contact sheets stay out of git.

**Classic, Stage and AURORA (55 looks):** 45 met the 8 jumps/min target before, all 55 after. Median per look:
flick p99 0.030 → 0.019, resid p99 0.024 → 0.017, dmean p99 0.019 → 0.014. Beat peak in the first 3 of 8 phase bins:
52 → 54 looks. Contact sheets of all 48 Classic presets at the groove and the drop still look as full as before.

| look | jumps/min | flick p99 | resid p99 | dmean p99 | beat contrast (peak bin) |
|---|---|---|---|---|---|
| Stage look 0 | 20.6 → 0.0 | 0.045 → 0.026 | 0.038 → 0.022 | 0.037 → 0.014 | 0.33 → 0.26 (0 → 1) |
| Stage look 1 | 33.0 → 0.0 | 0.047 → 0.019 | 0.039 → 0.018 | 0.041 → 0.016 | 0.32 → 0.30 (0 → 0) |
| Stage look 3 | 40.0 → 0.0 | 0.061 → 0.056 | 0.048 → 0.030 | 0.046 → 0.024 | 0.40 → 0.38 (0 → 0) |
| Stage look 4 | 33.1 → 0.0 | 0.045 → 0.023 | 0.039 → 0.020 | 0.045 → 0.021 | 0.45 → 0.41 (0 → 0) |
| Wormhole | 50.9 → 0.0 | 0.126 → 0.034 | 0.094 → 0.023 | 0.081 → 0.018 | 0.26 → 0.18 (0 → 0) |
| Bars | 16.5 → 5.5 | 0.095 → 0.063 | 0.080 → 0.049 | 0.094 → 0.061 | 0.92 → 0.56 (1 → 2) |
| Crystals | 13.8 → 1.4 | 0.073 → 0.040 | 0.069 → 0.040 | 0.072 → 0.038 | 0.99 → 0.63 (0 → 1) |
| Kick Cubes | 12.4 → 2.7 | 0.106 → 0.104 | 0.090 → 0.083 | 0.064 → 0.038 | 0.33 → 0.29 (0 → 0) |
| Plasma | 6.9 → 0.0 | 0.161 → 0.042 | 0.094 → 0.036 | 0.060 → 0.031 | 0.23 → 0.17 (0 → 0) |
| Laser Grid | 6.9 → 0.0 | 0.033 → 0.018 | 0.029 → 0.015 | 0.030 → 0.017 | 0.17 → 0.12 (0 → 0) |
| Northern Lights | 0.0 → 0.0 | 0.039 → 0.019 | 0.026 → 0.013 | 0.038 → 0.019 | 0.30 → 0.30 (1 → 1) |
| Hyperdrive (reference) | 0.0 → 0.0 | 0.030 → 0.022 | 0.022 → 0.017 | 0.005 → 0.003 | 0.15 → 0.16 (0 → 0) |
| Neon City (reference) | 0.0 → 0.0 | 0.028 → 0.021 | 0.024 → 0.020 | 0.015 → 0.011 | 0.14 → 0.14 (0 → 1) |
| AURORA | 0.0 → 0.0 | 0.026 → 0.027 | 0.025 → 0.025 | 0.019 → 0.016 | 0.19 → 0.24 (0 → 0) |

The beat contrast of the punchiest looks (Bars, Crystals) is lower because hits no longer jump to full in one frame,
but the peak stays on or just after the beat. Normal vs Wild on the same looks: Wild keeps higher on-beat contrast
(Stage look 3: 0.38 vs 0.50; Kick Cubes 0.29 vs 0.37) and more punch (Kick Cubes 2.7 vs 11 jumps/min).

**MilkDrop, 40 random pack presets (locked, no changes):** the biggest frame-to-frame changes got smaller on 39 of 40
(median flick p99 0.092 → 0.060, dmean p99 0.069 → 0.048). Presets built on per-frame noise (Skin Dots, pixel
"glitch" presets) still count many jumps (easing splits a long run into several short ones), which is why the
built-in set was picked by the probe: 149 of 650 candidates pass. In a 10-minute MILKDROP run with automatic
beat-locked changes, one-frame spikes went 11 → 0 after the IOSurface fix.

**Transitions (SHOW, `--show-hold 12`, built-in presets only).** Four 25-minute runs (two Normal, two Wild):

| type | count | glitch frames | max one-frame dmean / resid |
|---|---|---|---|
| drop cut (flash cut) | 56 | 0 | 0.87 / 0.86 (the cut on the drop itself) |
| iris | 203 | 0 | 0.27 / 0.26 |
| liquid melt | 201 | 0 | 0.12 / 0.16 |
| zoom punch | 180 | 8, all in one Wild run: a MilkDrop preset's own flashes (removed from the set since) | 0.37 / 0.33 |
| spin kaleido | 151 | 0 | 0.14 / 0.13 |
| glitch (Wild only) | 87 | 1 (the effect's own slice flip) | 0.19 / 0.17 |
| pixel dissolve (Wild only) | 78 | 32 (the effect's block flips) | 0.21 / 0.20 |

Confirmation on the final build (149 presets, calmer Wild MilkDrop), 12 minutes Normal + 12 minutes Wild: 223
transitions of all 7 types (12 more drop cuts), **0 glitch frames**; one-frame spikes 0 (Normal) and 2 (Wild, both
under 0.07). Frame time inside vs outside transitions: p50 16.8 vs 16.7 ms and p99 27-29 vs 24-25 ms with four
instances sharing the GPU; p99 17.4 vs 17.4 ms with two. Drops: 14 per 25 minutes (one per demo loop); before the drop
fix only the first drop of a session was found.

Before the MilkDrop texture fix, runs of the same length had 6-15 one-frame excursions each, almost all in or next to
a MilkDrop scene; a 10-minute MILKDROP run had 11, and 0 after.
