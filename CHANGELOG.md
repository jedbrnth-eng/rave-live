# Changelog

## [0.5.0] - Unreleased

### Added
- **Intel Macs and macOS 12 Monterey.** One universal app (Apple silicon + Intel) for macOS 12 and later. System audio needs macOS 13; on macOS 12 pick an input in the Audio menu (BlackHole works for system audio; see docs/COMPATIBILITY.md).
- **Audio menu:** System Audio, Default Input and every input device by name (mic, interface, DJ mixer, loopback driver); remembered, follows hot-plugging. `M` switches between system audio and the last input.
- **Quality tiers** (View → Quality: Auto / Low / Medium / High): Intel and AMD graphics get fewer AURORA particles, a lower render scale, lighter bloom and a lighter MilkDrop mesh. Apple silicon keeps the full look.
- **MILKDROP mode:** the community MilkDrop presets through projectM, with preset changes on the beat grid (blends on phrase downbeats, hard cut on drops, more zoom and saturation during builds). Preset pack download (asks first), your own `.milk` folder, a searchable browser (`P`), favourites (`Shift`+`F`), ratings (`1`–`5`), lock (`L`), and broken presets are skipped. SHOW mode now includes MILKDROP.
- **15 new Classic presets (33–47):** Datamosh, Julia, Rain Glass, Kick Cubes, String Art, Fireflies, Life, Subwoofer, Moire, XY Scope, Dancefloor, Disco Ball, Laser Show, Gravity Grid and Vinyl. Several react to the mouse or hands.
- **Shader Lab:** drop a `.metal` file into the Shaders folder (Visuals → Open Shader Folder…) and it plays as a Classic preset, reloads on save, and shows compile errors with your line number while the last working version keeps playing. Four examples and a template; guide in docs/SHADERS.md.
- **Tweak panel** (`Shift`+`T` in Classic Visuals): speed, hue, palette, density, feedback, symmetry and beat response per preset, saved as `.ravelook` files (`⌘S` / `⌘O`, double-click to open). A `community/` folder for sharing looks and shaders.
- **Syphon output** (Output → Syphon Server "RAVE LIVE", or `--syphon`): the final frame of every mode for Resolume, VDMX, OBS, MadMapper.
- **Send to Display:** a clean fullscreen output on a projector or second screen at its own resolution and refresh; the main window becomes a preview with the controls, and takes over again if the screen is unplugged.
- **MIDI:** MIDI Learn (`⌘L`) for 14 targets (mode, preset, intensity, master brightness, strobe through the 3-flashes-per-second limiter, blackout, tap, nudge, BPM, auto-cycle; preset and auto-cycle also drive MILKDROP), mappings saved as JSON with import/export, and MIDI clock (24 ppqn) tempo sync.
- **Control HUD** (`H`) and **keyboard cheat sheet** (`?`). Neither, nor the Tweak panel or Shader Lab errors, ever appears on Syphon or the output display.
- Docs: docs/COMPATIBILITY.md, docs/MILKDROP.md, docs/VJ.md, docs/SHADERS.md.

### Changed
- License changed from MIT to GPL-3.0 for all new work. Versions released before this change stay available under MIT.
- `F` is fullscreen in every mode.
- Input devices are captured with 512-frame buffers (lower latency, works with input-only devices).
- Snapshots also work on discrete GPUs.
- `scripts/make_app.sh` builds the universal app and bundles Syphon and libprojectM when `scripts/build_syphon.sh` / `scripts/build_projectm.sh` have been run; the app builds and runs without them. CI adds an Intel job and a headless smoke run.

### Fixed
- Frame rate no longer drops to about 5 fps when another app is in front (App Nap): Syphon and projector feeds keep full rate. While RAVE LIVE runs, the Mac doesn't idle-sleep.
- Opening an input device while the microphone permission prompt was still open froze the app on macOS 12.

## [0.4.0] - 2026-10-22

### Added
- Live audio analysis: FFT bands, spectral-flux onsets, kick/snare/hat pickers; system audio via ScreenCaptureKit with mic/line-in fallback.
- Tempo tracking: rolling autocorrelation tempo, phase-locked beat clock, tap tempo and nudge; guards against half/double and 3:2 locks.
- Optional Beat This! referee sidecar that corrects phase, tempo level and the bar line.
- Stage mode: LED wall, moving heads, lasers, haze, flame jets, fireballs and crowd, run by a show director with builds and drops.
- Classic Visuals: 33 presets; presets 23–32 (visuals packs 1 and 2, incl. Silk) react to the mouse or hands; all beat-driven motion reads one continuous, latency-compensated beat clock.
- AURORA: GPU fluid, about a million particles and bloom, with mouse and camera hand and body input.
- SHOW mode: a continuous set across all modes with 7 beat-locked transitions.
- Intensity setting (Chill / Normal / Wild), output-latency compensation, live metrics and frame snapshots for testing.
- App icon (Icon Composer bundle compiled with actool).
- Sync: referee rejects irregular Beat This! windows (sparse intros), kick-weighted causal phase with broadband refine (no off-beat locks on hat-heavy tracks), earlier referee start and a 0.1-beat soft-correction dead zone.
- `rave-probe live`: `RAVE_REFEREE` and `RAVE_BEATS_OUT` for scoring live system-audio sync against Beat This! ground truth.
- `--lumlog` probe (frame brightness vs beat phase) to prove visuals pulse on the beat.
- MIT license, `VERSION` file and a manual Release workflow.

### Changed
- The Beat This! referee is found next to the checkout the app was built from, or via `RAVE_REFEREE_DIR`; no machine-specific paths.
- `scripts/make_app.sh` reads the version from `VERSION` and falls back to ad-hoc signing when no Apple Development identity is installed, and to a plain `.icns` icon on Xcode versions before 26.
- `scripts/bench.py` takes your own track list (`bench.py [start] <tracks.json>`); no library data ships with the repo.

### Fixed
- Visuals: Terrain moon and drop haze, Pond ring contrast, Fireworks clipping at the frame edge, calmer Coral, Wormhole seam, Sphere terracing, gradient banding (dither), calmer Hyperdrive.
- Crash on rhythmless audio (regression test added).

### Safety
- Photosensitivity warning on first launch; strobes limited to 3 flashes per second unless the user confirms otherwise.
