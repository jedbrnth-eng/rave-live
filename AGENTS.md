# AGENTS.md

RAVE LIVE: native macOS (Swift + Metal, no package dependencies) live visualizer that listens to system audio and
drives a procedural stage, Classic shader presets, AURORA and MilkDrop (projectM).

## Commands (run from the repo root)
```
swift build -c release                       # all targets
swift test > test.log 2>&1                    # unit tests; check every "Executed" line has 0 failures
.build/release/rave-probe synth               # tempo tracker vs deterministic drum patterns
swift scripts/shadercheck.swift               # compile-check the Classic Visuals shaders
scripts/make_app.sh && scripts/check_app.sh   # build/RAVE LIVE.app (needs full Xcode for actool)
scripts/smoke_test.sh                         # headless run on synthetic audio, snapshot must not be black
bash -n install.sh && scripts/test_install.sh # installer checks
scripts/check_public_ready.sh                 # no personal data in tracked files
scripts/make_dmg.sh                           # (from CI, not run locally)
```
No linter is configured. Release steps: `docs/RELEASING.md`.

## Verification path
- Logic/tempo: `swift test` + `rave-probe synth`; after any tempo or beat change report lock times before and after.
- Visuals: render fixed frames and look at them, e.g.
  `open -n -W "build/RAVE LIVE.app" --args --accept-warning --demo --visuals --preset 24 --snap 20,41 --snapdir <dir> --metrics <dir>/metrics.json --autoquit 45`
- UI/keys: `--keys "h@4,h@7"` sends real key events; `--vjscript "3:shot=name"` saves the window with overlays.

## Layout
- `Sources/RaveAudio/`: analyzer (FFT, onsets, kick/snare/hat), `TempoTracker`, capture (ScreenCaptureKit, mic), `Synth`.
- `Sources/RaveProbe/`: `rave-probe` CLI (`synth | file <path> | live`).
- `Sources/RaveLiveApp/Renderer.swift`: modes, SHOW sequencer, transitions, strobe limiter, metrics, snapshots.
- `Sources/RaveLiveApp/Shaders.swift`: Stage shader; its uniform slot table must match `Renderer`.
- `Sources/RaveLiveApp/VisualsShader.swift`, `VisualsRenderer.swift`: Classic presets (`builtinNames`).
- `Sources/RaveLiveApp/Settings.swift`: `Prefs` and the Settings window (Cmd-,).
- `scripts/`: app/DMG build, vendor builds (Syphon, projectM, presets), checks. `docs/VJ.md`: key bindings.

## Rules
- Keep the photosensitivity warning and the 3-flashes/s strobe limit. Why: safety; new flashing must go through the limiter.
- No analytics, telemetry or network requests beyond documented, opt-in features. Why: privacy promise in CONTRIBUTING.md.
- Never commit audio or absolute home paths. Why: CI rejects `/Users/...`; benchmarks store BPM/beat times only.
- Every new source file gets the SPDX header from CONTRIBUTING.md. Why: credit must survive single-file copies.
- Shader edits: run the app once and look at a snapshot. Why: Metal source compiles at runtime, so errors only show then.
- Test runs (`--autoquit`, `--factory-settings`) must never write UserDefaults; command-line flags win over saved prefs.
  Why: a dev build shares the installed app's bundle id and settings.
- Always pass a unique `--metrics <path>`. Why: a running installed copy overwrites the default metrics file.
- In numeric code use plain loops and explicit types, not long chained closures. Why: CI's older Swift compiler
  times out type-checking them.
- Shell scripts run on macOS bash 3.2: write `${A[@]+"${A[@]}"}` for maybe-empty arrays under `set -u`.
- Don't put globals read by tests in `main.swift`. Why: top-level code doesn't run in unit tests.
- Map NaN/inf metrics to null before `JSONSerialization`. Why: it rejects them and the dump silently fails.
- `make_app.sh` exits 0 even without vendor pieces: `grep '^note' <log>` before calling a bundle complete.
- After any key change, update the in-app cheat sheet and `docs/VJ.md`. Why: they must match real bindings.

Learned something durable about this repo? Add one line here in your PR.
