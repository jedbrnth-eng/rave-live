# Compatibility: macOS 12+, Apple silicon and Intel

RAVE LIVE ships as one universal app (Apple silicon + Intel) that runs on **macOS 12 Monterey or later**.
Everything works everywhere except one thing: hearing what your Mac plays (system audio) needs macOS 13.

| | macOS 12 Monterey | macOS 13 Ventura and later |
|---|---|---|
| Apple silicon (M1 and newer) | ✅ input devices | ✅ system audio + input devices |
| Intel Mac with Metal | ✅ input devices | ✅ system audio + input devices |
| System audio (Spotify, YouTube, …) | via a loopback driver (below) | built in (Screen & System Audio Recording) |

## Picking the audio source

Use the **Audio** menu in the menu bar:

- **System Audio**: what your Mac is playing (macOS 13+). Greyed out on macOS 12.
- **Default Input**: whatever macOS uses as its input (System Settings → Sound → Input).
- **Every input device by name**: built-in mic, USB/Thunderbolt audio interfaces, DJ mixers and controllers with a
  sound card, and loopback drivers such as BlackHole or Loopback.

Your pick is remembered. Plugging or unplugging a device updates the menu; if the device you were using goes away,
RAVE LIVE falls back to the default input. `M` toggles between system audio and the last input you used.

DJs: run the mixer's booth or record output into an audio interface and pick the interface here. That gives
the tightest sync, because the audio doesn't go through the Mac's playback path at all.

## macOS 12: visualize system audio with BlackHole

macOS 12 can't hand system audio to apps directly. A free loopback driver does it instead:

1. Install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) (free, GPL-3.0). With Homebrew:
   `brew install blackhole-2ch`.
2. To keep hearing the music, open **Audio MIDI Setup**, click **+** → **Create Multi-Output Device**, and tick
   both your speakers/headphones and **BlackHole 2ch**. Choose that Multi-Output Device as the sound output
   (System Settings → Sound → Output).
3. In RAVE LIVE choose **Audio → BlackHole 2ch**.

Without the Multi-Output Device you'll see the visuals but hear nothing, because the audio goes only to BlackHole.
On macOS 13 and later you don't need any of this; just use System Audio.

## GPU quality tiers

RAVE LIVE picks a quality tier for your GPU at launch; you can override it in **View → Quality** (remembered)
or with `--quality low|medium|high|auto`.

| Tier | Picked for | AURORA particles | Render resolution | Bloom |
|---|---|---|---|---|
| High | Apple silicon (Metal GPU family Apple 7+) | 1,000,000 | 100% | two radii |
| Medium | Discrete GPUs (AMD Radeon in Intel Macs) | 500,000 | 80% | two radii |
| Low | Intel integrated GPUs (UHD/Iris) and other low-power GPUs | 250,000 | 60% | one radius |

Lower tiers render fewer pixels and let the window scale them up, and make each AURORA particle brighter so the
picture keeps the same overall brightness. High is exactly the look of earlier versions.
`RAVE_PARTICLES=<n>` still overrides the particle count in any tier.

## What was checked for this release

- Both slices are built for macOS 12.0 (`scripts/check_app.sh` checks `lipo` and `LC_BUILD_VERSION`; CI runs it).
- All Metal shaders compile with the Metal 2.3 language standard (macOS 11) and use no Apple-GPU-only features
  (no SIMD-group functions, tile shaders, imageblocks, programmable blending, memoryless textures or `half`-precision
  assumptions). Snapshot read-back synchronises managed textures, which discrete GPUs use.
- CI builds, tests and smoke-runs the app on an Intel runner (`macos-15-intel`) as well as Apple silicon.
  The smoke run skips with a clear message when the runner has no GPU.
- The x86_64 slice was run under Rosetta on Apple silicon in all four modes.

Not yet checked on real hardware: an Intel Mac with an Intel UHD/Iris or AMD GPU, and a physical macOS 12 Mac.
If you have one, please run `open -n "/Applications/RAVE LIVE.app" --args --demo` and report how it looks and the fps
from the status bar in an issue.

## Building from source

Building needs Xcode 15.3 or later (Swift 5.10), which needs macOS 13.5 or later. The app it builds runs on macOS 12.
`scripts/make_app.sh` builds the universal app; `RAVE_ARCHS=arm64 scripts/make_app.sh` builds one slice for faster
local iterations.

## Testing switches

| Switch | What it does |
|---|---|
| `--input "<name>"` | Listen to the first input device whose name contains the text (not saved) |
| `--mic` | Listen to the default input |
| `--quality low\|medium\|high\|auto` | Force a quality tier for this run (not saved) |
| `RAVE_NO_SYSTEM_AUDIO=1` | Behave as on macOS 12: System Audio greyed out, input devices only |
| `rave-probe live 10 --input "<name>"` | Command-line capture test on one input device |
