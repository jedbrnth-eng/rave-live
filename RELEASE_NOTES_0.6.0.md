<!--
Draft of the GitHub release notes for v0.6.0. Not published.
Everything below this comment is exactly what .github/workflows/release.yml will publish:
.github/release-notes.md, a blank line, then the "## [0.6.0]" section of CHANGELOG.md under "## Changes in this version".
Check it still matches before releasing (docs/RELEASING.md, step 2). Delete this file after the release.
-->

## Download

1. Download **RAVE-LIVE.dmg** below (under Assets) and double-click it.
2. Drag **RAVE LIVE** onto the **Applications** shortcut in the window that opens.
3. Open RAVE LIVE from Applications. It isn't notarized by Apple, so macOS will say it can't verify the app. Click **Done**, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to RAVE LIVE, then confirm. You only do this once.
4. Allow **Screen & System Audio Recording** when asked. macOS needs it to let RAVE LIVE hear what your Mac is playing; nothing is recorded.

Prefer one command? Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/jedbrnth-eng/rave-live/main/install.sh | bash
```

Runs on Apple silicon and Intel Macs with macOS 12 Monterey or later (system audio capture needs macOS 13; on macOS 12 pick an input in the Audio menu, see docs/COMPATIBILITY.md). Please read the photosensitivity warning in the README before using strobes.

## Changes in this version

### Added
- **Synced lyrics** for whatever your Mac is playing (Spotify, Music, browsers, most players): the current line large and low on screen (or centred), the next line smaller below, and a clean change between lines (the old line fades out before the new one comes in, so they never overlap). No box or dark shape behind the text: a thin outline and a tight shadow on each letter keep it readable. Lines follow the player's own position, which already counts Bluetooth and other output delays, and go up 150 ms early so reading keeps up with the singer; a lyrics timing trim (±1000 ms; `-` / `=` move it 50 ms) covers the rest. Lyrics come from [lrclib.net](https://lrclib.net) and are cached on your Mac.
- **Lyric styles** (Settings → Lyrics style, `Shift-Y` cycles): **Clean** (default), **Neon karaoke**, **Pop**, **Bass wave**, **Spectrum** and **Auto**. They react to the music RAVE LIVE hears (beat, kick, bass, energy, drops), not just to the clock. Words are revealed one by one: from word timing when the lyrics have it, otherwise spread over the line by syllables and snapped to the live beat grid. Auto picks a style from the energy and cuts to Pop on drops.
- **Lyrics are off by default** because they send the playing track's title, artist, album and length to lrclib.net. Turn them on in Settings or with `Y`.
- **Remix guard:** remixes, edits, bootlegs, VIPs, flips, mashups and sped-up / slowed / nightcore / 8D versions are never looked up and show no lyrics, and lyrics stay off when the track length is more than 3 s from the match, since original-song timing doesn't fit them. The card says "skipped: remix/edit".
- **Now Playing card** (bottom left): artwork, title, artist, source app, progress, and previous / play-pause / next buttons that control the playing app. It hides a few seconds after the mouse stops; `N` turns it off. HUD off hides it and the lyrics.
- **Settings → Lyrics**: an on/off switch that follows the `Y` key (and the other way round), style, position (lower third / centre), size and timing, the player card on/off, and what Now Playing sees (or why it can't).
- States shown on the card: "lyrics offline" (retried after 30 s, then less often), "instrumental", "no synced lyrics", "skipped: remix/edit".
- Now Playing comes from [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause), built from a pinned tag by `scripts/build_mediaremote_adapter.sh` and bundled by `make_app.sh`. Builds without it run as before.

### Notes
- Lyrics and the card are on the main window only, like the HUD; they are never sent to Syphon or the output display.
- The lyrics cost about 0.3-0.5 ms of main-thread time per frame (p95) and only move layers: frame-interval p95 was 14.5-14.6 ms with each style and with lyrics off (72 fps target, demo audio, one Mac).

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

