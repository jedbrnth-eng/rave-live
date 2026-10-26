# MILKDROP mode

RAVE LIVE plays MilkDrop presets (`.milk`), the format behind 20 years of community visuals, through
[projectM](https://github.com/projectM-visualizer/projectm), the open-source MilkDrop engine.
The difference from plain MilkDrop/projectM: **preset changes follow the music's structure.**

- Changes land on **phrase lines**: a soft blend starts on the downbeat that opens a 16-beat phrase, after the preset
  has held for 32 beats (16 on Wild when the music is loud, 64 on Chill). The blend lasts 2 bars, so it also ends on a bar line.
  Never mid-bar.
- **Drops get a hard cut**, on the drop itself, to a preset from the high-energy categories.
- **Intensity follows the build**: during a build-up the image creeps in and gets more saturated, kicks give a small
  punch, and projectM's own beat sensitivity rises with the build and the drop (capped: 0.8–1.3 on Normal, up to 2.4
  on Wild, so presets don't spasm).
- **Smooth on Normal**: projectM renders at most ~75 frames per second (presets are made for ~60; at 120 Hz they used
  to run at double speed), and on Normal / Chill each frame eases toward the next, so one-frame flicker becomes a quick
  fade. Wild shows projectM's frames as they are. See docs/SMOOTHNESS.md.
- Without a tempo lock yet (silence, free-form music) it falls back to a change every 24 s.

## Getting presets

**Built in:** about 150 presets from projectM's
[cream of the crop](https://github.com/projectM-visualizer/presets-cream-of-the-crop) pack ship inside the app, so
MILKDROP plays right away. They were picked by a sweep of ~400 candidates from every category: each loads without
errors, isn't black or blown out, renders a frame in under 16 ms here, and passes the smoothness limits of
docs/SMOOTHNESS.md (at most 8 off-beat pops a minute); then at most a few per sub-category and per author, so the set
is varied. The list is `Resources/MilkDrop/bundled.txt` (pack commit + SHA-256 of every file);
`scripts/fetch_milkdrop_presets.sh` fetches exactly those files and `make_app.sh` copies them into the app with the
pack's LICENSE.md and an AUTHORS.txt.

**More:**

- **Get 9,800 More Presets…** (View menu and the preset browser) downloads the whole pack (a 32 MB download, about
  130 MB on disk) into `~/Library/Application Support/RAVE LIVE/MilkDrop/presets`. It asks first and shows the size.
- **Drag and drop** `.milk` files or folders onto the RAVE LIVE window (or the preset browser): they are copied into
  `~/Library/Application Support/RAVE LIVE/MilkDrop/My Presets` and the first one plays.
- **Add MilkDrop Preset Folder…** (View menu, or Add Folder… in the browser) does the same through a file dialog.
- **Open My MilkDrop Presets Folder…** opens that folder; press Rescan in the browser after changing it by hand.

The browser (`P`) has tabs: All, Bundled, Downloaded, Mine. A built-in preset that is also in the downloaded pack is
listed once (favourites and ratings are shared). About the presets' licence: most MilkDrop presets were released
without one; the projectM team treats them as public domain and removes any on the author's request (see the pack's
LICENSE.md, also in the app). The authors of the built-in presets are listed in CREDITS.md and in AUTHORS.txt in the
app.

## Controls (MILKDROP mode)

| Key | Action |
| --- | --- |
| `]` / `[` | next / previous preset (alphabetical) |
| `R` | random preset (short blend) |
| `Shift-F` | favourite the current preset (plain `F` is fullscreen, as in every mode) |
| `L` | lock the current preset (no automatic changes, drops included) |
| `1`–`5`, `0` | rate the current preset, clear the rating |
| `P` / cmd-P | preset browser: search by name, author or category, favourites filter, double-click to play |
| `V`, cmd-5 | cycle modes / jump to MILKDROP |

Automatic picks prefer favourites (4x) and higher ratings, skip 1-star presets, avoid recent repeats, and prefer
loud categories (Sparkle, Supernova, Dancer, Waveform, Geometric) for drops and loud moments and calm ones otherwise.
Favourites, ratings and the broken list are saved in `~/Library/Application Support/RAVE LIVE/MilkDrop/library.json`.

**Skip broken:** a preset that fails to load, or is still pitch black 3–6 s after loading while music plays, is skipped
and remembered (shown as "(broken)" in the browser). The pack's `! Transition` folder (fade-to-black presets) is never
picked automatically.

## SHOW mode

When the engine and presets are there, SHOW also rotates through MILKDROP (3 of 18 slots per shuffle cycle) with the
same 7 transitions as the other scenes; each visit loads a fresh preset. `--no-show-milkdrop` turns that off.

## How it works

- `scripts/build_projectm.sh` fetches the pinned projectM 4.1.8 release source (SHA-256 checked) into `vendor/`
  (gitignored), applies `scripts/projectm-patches/*.patch` and builds a universal (arm64 + x86_64), macOS 12.0+
  `libprojectM-4.dylib`. `scripts/make_app.sh` copies it to `RAVE LIVE.app/Contents/Frameworks/` when it exists.
- The one patch adds `projectm_opengl_render_frame_fbo()`: projectM 4.1 always draws its final image into framebuffer 0,
  and an offscreen context has none.
- `MilkDropLib.swift` loads the library with `dlopen` at runtime. RAVE LIVE builds and runs without it (CI does): the
  mode then shows an "engine missing" card. Swapping in your own libprojectM build is just replacing the file (LGPL).
  Search order: `RAVE_PROJECTM_LIB`, the bundle's Frameworks, `./vendor/projectm/lib` (for `swift run` from a checkout).
- `MilkDropRenderer.swift`: a CGL OpenGL 4.1 core context on its own serial queue renders projectM into a ring of three
  IOSurfaces (bound to GL rectangle textures + FBOs). The same IOSurfaces are Metal textures (zero copy). The Metal
  render loop never waits for GL: each frame it starts the next GL frame if the GL queue is idle and draws the newest
  finished one through a small composite shader (beat punch, build saturation, limiter-gated blinder, fade, blackout).
  projectM renders at most 1920 px wide; Metal scales to the drawable.
- Audio: `AudioEngine.onPCM` hands the captured mono samples to a small buffer that the GL thread feeds to
  `projectm_pcm_add_float` each frame.
- `MilkDropDirector.swift` is the pure beat-grid logic (unit-tested in `Tests/RaveLiveAppTests`). It keeps its own
  beat counter that only advances when the beat phase wraps, and adopts the renderer's bar/phrase alignment on a drop
  or once it has been stable for 8 beats: the renderer's bar estimate can flip by 2 beats back and forth, and a phrase
  change must not follow that.

## Test flags

```
--milkdrop                      start in MILKDROP mode
--milk-preset <file.milk>       start with this preset
--milk-lock                     no automatic changes
--milk-dir <dir>                scan an extra preset folder
--milk-store <file.json>        favourites/ratings/broken list file (keeps tests away from the real one)
--milk-sweep N [--milk-sweep-secs S] [--milk-sweep-seed K] [--milk-sweep-list file]
                                load N presets back to back, classify each ok / failed / black, write
                                sweep.tsv, sweep_summary.txt and a thumbnail per preset into --snapdir
--no-show-milkdrop              keep MILKDROP out of the SHOW rotation
--milk-download-now             run the "Get presets" download without the confirmation dialog
--milk-ui-shot <file.png>       save the AppKit overlay (card, HUD) after 4 s; the Metal layer is not included
env RAVE_MILKDROP_ROOT=<dir>    use <dir> instead of ~/Library/Application Support/RAVE LIVE/MilkDrop
env RAVE_MILKDROP_BUNDLED=<dir> use <dir> as the built-in set (e.g. vendor/milkdrop-bundled with `swift run`)
env RAVE_PROJECTM_LIB=<dylib>   load this libprojectM build first
```

Events in the metrics JSON: `milk:blend beat=N bar=B phrase=P phase=X locked=1 <name>`, `milk:cut(drop) …`,
`milk:loaded(<why>) <name> [<load ms>]`, `milk:skip(failed|black) …`, `milk:import N`. The sweep's `sweep.tsv` also has
the mean GL frame time per preset (`gl_ms`).

## Known limits

- OpenGL is deprecated on macOS but still present (macOS 12 through 27, Intel and Apple Silicon). If Apple removes it,
  MILKDROP shows its card instead of crashing; a Metal port of projectM's renderer would be the long-term fix.
- Loading a preset compiles its shaders on the GL thread (median ~30 ms on an M-series Mac). During that time the
  last frame stays on screen; the Metal loop keeps running.
- Presets that need textures not in the pack (some use `fw_`/`noise` images) render without them.
