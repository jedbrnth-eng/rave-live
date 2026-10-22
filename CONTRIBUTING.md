# Contributing to RAVE LIVE

Thanks for taking a look. RAVE LIVE is a native macOS app in Swift and Metal with no Swift package dependencies.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build
```
swift build -c release           # all targets
scripts/make_app.sh              # creates build/RAVE LIVE.app (needs full Xcode for actool)
open "build/RAVE LIVE.app" --args --demo
```
Requires macOS 14 or later.

## Test
```
swift test                                  # unit tests (tempo tracking, referee gate and startup)
.build/release/rave-probe synth             # tracker vs deterministic drum patterns
swift scripts/shadercheck.swift             # compile-check the Classic Visuals shaders
```
Shader errors only show up at runtime, so after any shader edit also run the app once (`--demo --snap 5`) and look at the frame.

For visual changes, attach before/after frames rendered at fixed times:
```
open -n -W "build/RAVE LIVE.app" --args --accept-warning --demo --visuals --preset 24 \
  --snap 20,41 --snapdir /tmp/rave-snaps --metrics /tmp/rave-metrics.json --autoquit 45
```

## Guidelines
- **Safety first.** Keep the photosensitivity warning and the default 3-flashes-per-second strobe limit. Any change that adds flashing must respect the limiter.
- **After any tempo or beat change,** run `swift test` and `rave-probe synth`, and report lock times before and after.
- Keep the privacy promise: no analytics, no telemetry, no network requests from the app.
- **Never commit audio or personal paths.** Benchmarks store BPM and beat times only, with paths relative to `~` (CI rejects `/Users/...`).
- Open an issue before a large change so we can agree on the approach.

## Pull requests
Branch from `main`, keep each PR to one concern, make sure CI passes, and fill in the PR template.
