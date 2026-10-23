# Changelog

## Unreleased

- License changed from MIT to GPL-3.0 for all new work. Versions released before this change stay available under MIT.

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
