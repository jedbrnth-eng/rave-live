# Shader Lab: make your own RAVE LIVE visual in 5 minutes

RAVE LIVE plays any `.metal` file you drop into its Shader Lab folder as a Classic Visuals preset, beat-locked like the
built-in ones. You don't need Xcode or any graphics experience: a text editor is enough. Save the file and the visual
updates while the music plays.

## 1. Open the folder

In RAVE LIVE choose **Visuals → Open Shader Folder…**. It opens:

    ~/Library/Application Support/RAVE LIVE/Shaders/

On first launch RAVE LIVE copies four examples and a starter template there:

| file | what it shows you |
|---|---|
| `pulse_rings.metal` | the beat clock: one ring per beat, brighter on the downbeat |
| `spectrum_bloom.metal` | the live spectrum, drawn as flower petals |
| `feedback_tunnel.metal` | feedback: drawing on top of your own last frame |
| `pointer_paint.metal` | mouse and camera hands |
| `_template.metal` | a starter file (names that start with `_` are not loaded) |

## 2. Copy the template

Duplicate `_template.metal` and rename the copy, for example to `my_first.metal`. Drop the leading `_`, or the file
won't load.

## 3. Show it

Switch to **Classic Visuals** (⌘3) and press `]` until the name at the bottom says `Lab: my_first`. Shader Lab
presets come after the 48 built-ins. Auto-cycle never picks them, so a half-finished shader can't land in your set.
Use `[` and `]` to step through them.

## 4. Edit and save

Open `my_first.metal` in any text editor (TextEdit works; VS Code or Sublime colour the code). It looks like this:

```metal
float4 rave(Rave r) {
    float2 p = r.p;                                   // centred coordinates, y up
    float d = abs(length(p) - 0.4 - 0.2 * r.kick);    // distance to a ring that kicks outward on the bass drum
    float3 color = palette(r.hue + r.beat * 0.05);    // colour slowly cycles with the beat clock
    float glow = exp(-d * 30.0) * (0.4 + beatPulse(r, 6.0));
    return float4(color * glow, 1.0);
}
```

RAVE LIVE calls `rave` once for every pixel, every frame, and you return that pixel's colour (red, green, blue and an
alpha it ignores). Values go from 0 (dark) to 1 (full); brighter values are clipped.

Try these, saving after each one:

1. Change `0.4` to `0.7`: the ring gets bigger.
2. Change `30.0` to `8.0`: the ring gets soft and wide.
3. Change `r.kick` to `r.bass`: the ring now breathes with the bass instead of jumping on kicks.
4. Replace the `return` line with `return float4(color * glow * spectrum(r, length(p)), 1.0);` so the ring lights up
   with the spectrum.

## 5. When it breaks

If you make a typo, RAVE LIVE doesn't crash. A red box shows the line number, the compiler's message and the line
itself. The last version that worked keeps playing until you fix the line and save again.

```
SHADER LAB · my_first.metal didn't compile
line 5: use of undeclared identifier 'colr'
    5 | return float4(colr * glow, 1.0);
```

Common mistakes:
- Writing `1` where a decimal is needed is usually fine, but `float3(1, 0, 0)` is the safe way to write a colour.
- Every line ends with `;`.
- The file must contain `float4 rave(Rave r) { ... }`.

## What you get in `r` (the `Rave` struct)

| field | meaning |
|---|---|
| `r.uv` | pixel position, 0..1, origin bottom-left (like Shadertoy's `fragCoord / iResolution`) |
| `r.p` | centred position: x from -aspect to +aspect, y from -1 to 1 (y up). Use this for shapes. |
| `r.resolution`, `r.aspect` | output size in pixels, width / height |
| `r.time`, `r.dt`, `r.frame` | seconds since start, seconds since the last frame, frame counter |
| `r.beat` | **beat clock** in beats. Whole numbers land exactly on the beat (latency-compensated). Free-runs at 120 BPM until the tempo locks. |
| `r.beatPhase` | 0..1 inside the current beat (0 = on the beat) |
| `r.barPhase` | 0..1 inside the current 4-beat bar (0 = the downbeat) |
| `r.bpm` | tempo (0 until locked) |
| `r.bass`, `r.mid`, `r.high`, `r.energy` | levels, 0..1 |
| `r.kick`, `r.snare`, `r.hat` | hit envelopes: 1 on a hit, then they decay |
| `r.build`, `r.drop` | song structure, 0..1: rises during a build-up, high during a drop |
| `r.hue` | a slowly drifting colour offset (the same one the built-ins use) |
| `r.variation` | random 0..1, new every time the preset comes up |
| `r.pointerCount`, `r.pointer[i]` | mouse + camera hands (up to 3): `.xy` in `r.p` units, `.z` strength (0.5 hover, 1 pressed or a hand) |
| `r.click` | last click or pinch: `.xy` position, `.z` age in seconds (99 = none) |

Helpers:

| helper | what it does |
|---|---|
| `spectrum(r, x)` | spectrum level 0..1 at `x` (0 = bass .. 1 = treble). 512 texels, interpolated from the 128-band log spectrum. |
| `waveform(r, x)` | the waveform (-1..1) at `x` 0..1; 512 samples, trigger-aligned so it stands still |
| `previous(r, uv)` | **feedback**: your own previous frame at `uv`. Zoom, rotate or fade it for tunnels and trails (see `feedback_tunnel.metal`). |
| `beatPulse(r, k)` | 1 on the beat, fading out (bigger `k` = shorter flash) |
| `palette(t)` / `palette(t, a, b, c, d)` | cosine colour palettes (Inigo Quilez's formula) |
| `hash(p)`, `noise(p)` | pseudo-random number and smooth value noise |
| `rotate(p, angle)` | rotate a 2D point |
| `PI` | 3.14159… |

You can write your own helper functions above `rave`, like in any Metal or C file.

## Beat lock

The built-in presets look "on the beat" because every motion and flash is a function of `r.beat`:

- **Pulses:** `beatPulse(r, 6.0)` or `exp(-r.beatPhase * 6.0)` peak exactly on the beat.
- **Steps:** `floor(r.beat)` changes once per beat. Use it to pick a new position, colour or pattern every beat
  (`hash(float2(floor(r.beat), 1.0))`).
- **Travel:** `fract(r.beat * 0.25)` goes 0→1 once per bar, so things that move with it loop on the bar.
- **Smooth steps:** `floor(b) + smoothstep(0.0, 0.3, fract(b))` moves quickly at the start of each beat, then holds.

Avoid driving the whole screen from black to white on every beat. RAVE LIVE limits its own strobes to 3 flashes per
second for photosensitive viewers, and your shader should be gentle too: keep big brightness changes to accents, not
full-frame flashes.

## Porting from Shadertoy

| Shadertoy | Shader Lab |
|---|---|
| `void mainImage(out vec4 c, in vec2 fragCoord)` | `float4 rave(Rave r)` and `return` the colour |
| `fragCoord / iResolution.xy` | `r.uv` |
| `iTime` | `r.time`, or better `r.beat` for beat-locked motion |
| `vec2 / vec3 / vec4` | `float2 / float3 / float4` |
| `mix, fract, smoothstep, ...` | same names |
| `mod(x, y)` | `fmod(x, y)` (careful: negative numbers behave differently) |
| `texture(iChannel0, uv)` | `previous(r, uv)` for a buffer feedback loop; `spectrum(r, x)` for the audio texture |
| `atan(y, x)` | `atan2(y, x)` |
| `const` at file level | `constant float X = 1.0;` |

Only port code whose licence allows it, and keep the original author's credit and licence line in your file.

## Compatibility

Shaders compile at runtime on every Mac that runs RAVE LIVE, including Intel and AMD GPUs. Stick to plain Metal maths.
Don't use `simd_*` / `simdgroup` functions, threadgroup memory or Apple-GPU-only features. Long loops (more than a few
hundred iterations per pixel) can slow older Macs down.

## Look presets (`.ravelook`)

Any preset, built-in or Shader Lab, can be tweaked without code. In Classic Visuals press **Shift+T** (plain `T` is
still tap tempo) for the Tweak panel:

| row | effect |
|---|---|
| Speed | 0.25× / 0.5× / 1× / 2×. Only these multiples, so motion stays on the beat. |
| Hue shift | turns the colours round the colour wheel |
| Palette | auto (new each visit) or one of 7 fixed palettes |
| Density | zooms the pattern out (more) or in (less) |
| Feedback | adds trails to any preset |
| Symmetry | mirror, or a 3- to 12-fold kaleidoscope |
| Beat react | how hard kicks, beats and snares hit (0 = calm, 2 = double) |

Keys: ↑↓ pick a row, ←→ change it, `R` resets the preset, Esc or Shift+T closes the panel. **Visuals → Save Look…**
(⌘S) writes a `.ravelook` file. Double-click one, or use **Visuals → Open Look…** (⌘O), to load it. Tweaks are also
remembered per preset between launches.

A `.ravelook` is small, readable JSON, so it's easy to share:

```json
{
  "format": "ravelook",
  "version": 1,
  "preset": "Kick Cubes",
  "name": "Kick Cubes",
  "app": "RAVE LIVE 0.5.0",
  "params": { "speed": 2, "hueShift": 0.25, "palette": 3, "density": 1.3, "feedback": 0.4, "symmetry": 6, "beat": 1.5 }
}
```

`preset` is the preset's name as shown in the HUD. For Shader Lab presets it is `Lab: <file name>`, so the person
opening the look needs that `.metal` file too. Missing params fall back to their defaults, and unknown keys are ignored.

## Sharing

See [community/README.md](../community/README.md) to send your shader or look to the RAVE LIVE community folder.
