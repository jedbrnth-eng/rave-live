# Changelog

## [0.6.0]

### Added
- **Synced lyrics** for whatever your Mac is playing (Spotify, Music, browsers, most players): the current line large and low in the middle, the next line smaller below, a smooth crossfade between lines and a very gentle breath on the beat (no flashing). Timing follows the audio output latency, plus a lyrics timing trim (±1000 ms; `-` / `=` move it 50 ms). Lyrics come from [lrclib.net](https://lrclib.net) and are cached on your Mac.
- **Lyrics are off by default** because they send the playing track's title, artist, album and length to lrclib.net. Turn them on in Settings or with `Y`.
- **Remix guard:** remixes, edits, bootlegs, VIPs, flips, mashups and sped-up / slowed / nightcore / 8D versions are never looked up and show no lyrics, and lyrics stay off when the track length is more than 3 s from the match, since original-song timing doesn't fit them. The card says "skipped: remix/edit".
- **Now Playing card** (bottom left): artwork, title, artist, source app, progress, and previous / play-pause / next buttons that control the playing app. It hides a few seconds after the mouse stops; `N` turns it off. HUD off hides it and the lyrics.
- Settings rows: Lyrics on/off, lyrics size, lyrics timing, player card on/off, and what Now Playing sees (or why it can't).
- States shown on the card: "lyrics offline" (retried after 30 s, then less often), "instrumental", "no synced lyrics", "skipped: remix/edit".
- Now Playing comes from [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause), built from a pinned tag by `scripts/build_mediaremote_adapter.sh` and bundled by `make_app.sh`. Builds without it run as before.

### Notes
- Lyrics and the card are on the main window only, like the HUD; they are never sent to Syphon or the output display.

### Fixed (lyrics in the real world: YouTube in a browser, a busy lrclib.net)
- **No more silent "nothing"**: a small line where the lyrics go and the card always say why there are no lyrics ("Lyrics off (Y)", "Looking up lyrics…", "No synced lyrics found", "Lyrics server busy, retrying", "Skipped: remix/edit", "Skipped: video length … doesn't match the song (…)", "Skipped: long video/mix"). The full HUD has a "Lyrics" debug row (source app, looked-up title/artist, the two lengths, the decision).
- **YouTube in a browser**: titles lose "(Official Video)", "[Official Music Video]", "(Lyrics)", "ft. …" and "| …"; "Artist - Title" is split and the channel ("- Topic", "VEVO") is the artist otherwise. Music videos up to 90 s longer than the song sync with that intro assumed; uploads over twice the song's length are skipped as a long video/mix.
- **`L` syncs a skipped song anyway** (Shift-L in MILKDROP), `L` again undoes it; **Shift - / Shift =** move the lyrics 1 s for the current song.
- **lrclib.net overload (503/429)**: exponential backoff with jitter that honours `Retry-After`, `/api/search` straight after a failed `/api/get`, a "busy" state retried after 10 s, 20 s … 10 min, and never cached.

### Fixed (performance and robustness audit)
- **No more stutter every 2 seconds in long sets.** The metrics file was rebuilt on the render thread every 2 s by sorting every frame time of the set, so the hitch grew with set length (70-245 ms after half an hour at 120 fps). Statistics now live in fixed-size histograms and the file is written in the background; the render thread spends about 0.01 ms on it at any set length. Without `--metrics` the file is written every 10 s.
- **The Now Playing reader can no longer outlive RAVE LIVE**: quick `Y` / `N` toggles left it running in the background, and so did a crash or force quit. It is now killed if it ignores the stop request, and it watches the app and exits when the app is gone.
- **System audio comes back on its own** after sleep/wake, a display change, or when macOS stops the capture. It restarts within a second (with backoff if that fails) instead of going silent until a relaunch.
- **Hotel / festival Wi-Fi login pages no longer stick "no synced lyrics" to a song for 3 days**: an answer that isn't LRCLIB data counts as offline and isn't cached. Offline retries back off (30 s, 1, 2, 4 … 10 min).
- **Lyrics use less CPU**: the beat breath scales the line on the GPU instead of rebuilding the text 30 times a second.
- **Syphon keeps the full frame rate while the main window is covered** (it dropped to about 60 fps on a 120 Hz Mac).
- **First launch after an install or update shows the window at once** and prepares the visuals in the background (the window used to take several seconds, up to ~15 s under load, to appear).
- `⌘,` with Settings already open no longer stalls the visuals; `P` closes the MilkDrop browser again and no longer takes the keyboard; MILKDROP keys don't refresh a hidden browser.
- The HUD shows "–" instead of "nan ms" before any latency is measured.
- `M` (audio source) no longer saves the choice during test runs (`--autoquit`, `--factory-settings`).
- The metrics event log is capped (first 200 + newest entries, 2000 in all), long lines are cut, and track titles in it are replaced by a short hash.
- Deleting the Shader Lab file of the preset that is playing can no longer crash SHOW or the HUD.

## [0.5.1] - 2026-10-29

### Added
- **Settings window** (RAVE LIVE → Settings…, `⌘,`): HUD level, which mode to open in (or the last one used), open in fullscreen, intensity, strobes, audio source, quality, and a visual sync slider (±250 ms) for Bluetooth speakers. Everything acts immediately and is remembered.
- **HUD off for a clean picture:** `H` now cycles status line → full Control HUD → off. Off also hides the mode bar, so nothing covers the visuals (permission and error messages still show). Output → HUD has the same three choices. The level is remembered between launches.

### Changed
- Intensity, strobes on/off, the `,` `.` sync trim and the last mode are remembered between launches. The strobe limit lift (`Shift`+`S`) is never remembered.
- Command-line flags still win over saved settings, and test runs (`--autoquit`, or `--factory-settings`) ignore saved settings and never save.

## [0.5.0] - 2026-10-26

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
- **MilkDrop presets built in:** about 150 curated presets from the projectM "cream of the crop" pack ship with the app, so MILKDROP works out of the box. They were picked to load cleanly, run fast and pass the new smoothness checks, across all categories and dozens of authors. One click gets the other 9,800 (View → Get 9,800 More MilkDrop Presets…). Drag `.milk` files or whole folders onto the window to add your own, or use View → Add MilkDrop Preset Folder…. The browser has All / Bundled / Downloaded / Mine tabs.
- `--smoothlog` probe and `scripts/smooth_report.py`: per-frame flicker, pops and motion of the final frame, per preset and per transition. Limits and method in docs/SMOOTHNESS.md.
- Docs: docs/COMPATIBILITY.md, docs/MILKDROP.md, docs/VJ.md, docs/SHADERS.md, docs/SMOOTHNESS.md.

### Changed
- License changed from MIT to GPL-3.0 for all new work. Versions released before this change stay available under MIT.
- **Smoother everywhere, still on the beat.** Kicks, snares and the beat pulse ease in and out instead of switching on for one frame; the beat pulse peaks exactly on the beat. Band levels and the spectrum are smoothed, so full-screen fields no longer shimmer with noisy audio. On Normal the strobe eases in and out (still at most 3 flashes per second); Wild keeps the hard strobe. Stage's build-up wall pulse is a soft pulse once per beat, and the camera shake is slower and gentler. Calmer Wormhole, Crystals, Nebula and Plasma.
- **Smoother transitions.** SHOW starts the next scene a bar early offscreen, so it fades in already running (no empty or stale first frames); transitions can't jump when the tempo lock changes; the drop cut is one clean cut with a smaller white bloom on Normal. Classic Visuals crossfades between presets instead of cutting.
- **MILKDROP is calmer:** projectM's beat sensitivity is capped (Normal 0.8–1.3, was up to 3.5), and on Normal and Chill each frame eases toward the next, so twitchy presets don't spasm.
- Community shaders and looks are licensed GPL-3.0-or-later (community/README.md).
- `F` is fullscreen in every mode.
- Input devices are captured with 512-frame buffers (lower latency, works with input-only devices).
- Snapshots also work on discrete GPUs.
- `scripts/make_app.sh` builds the universal app and bundles Syphon and libprojectM when `scripts/build_syphon.sh` / `scripts/build_projectm.sh` have been run; the app builds and runs without them. CI adds an Intel job and a headless smoke run.

### Fixed
- Beat-locked motion jumped back and forth by 2–3 beats about every beat on four-on-the-floor music: the bar estimate flipped, and the beat counter followed it. Wormhole, Laser Grid, Terrain, Stage patterns and others lurched. The counter now only moves to a new bar alignment after 8 beats of agreement, or on a drop.
- MilkDrop presets ran at double speed on 120 Hz displays (projectM rendered a frame per display frame); it now renders at most ~75 frames per second.
- The Stage build-up flashed the LED wall up to 8.5 times per second, off the beat, outside the strobe limiter.
- SHOW: a scene could transition into itself, and a scene could open on a frame from its previous visit.
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
