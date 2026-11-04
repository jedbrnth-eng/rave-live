# RAVE LIVE in a VJ rig

RAVE LIVE can send its visuals to other video apps over Syphon, take orders from a MIDI controller, follow a MIDI clock,
and run a clean fullscreen output on a projector while you control it from the laptop.

## Syphon output (Resolume, VDMX, OBS, MadMapper, Millumin…)

**Output > Syphon Server "RAVE LIVE"** (or launch with `--syphon`). The server publishes the final frame of every mode
(SHOW, Stage, Classic, AURORA, MILKDROP, Shader Lab, transitions included) at the render resolution. In OBS, add a *Syphon Client* source and
pick `RAVE LIVE`. The Control HUD, the cheat sheet, the Tweak panel and Shader Lab error messages are never part of the published frame.

Syphon support comes from [Syphon-Framework](https://github.com/Syphon/Syphon-Framework) (BSD-3-Clause). It is optional:
`scripts/build_syphon.sh` builds a universal (arm64 + x86_64, macOS 12+) `vendor/Syphon.framework` from a pinned source
commit, and `scripts/make_app.sh` bundles it when it exists. Without it the menu item is disabled and says why.

Check it works: start RAVE LIVE with Syphon on, then run `scripts/syphon_client.sh 4 frame.png` — it connects like any
client, prints frame size / frame rate / non-black share and saves the frame.

## Projector / second display

**Output > Send to Display ▸ <screen>** opens a borderless fullscreen window on that screen showing only the visual. The
renderer then draws at that screen's resolution and frame rate (smallest whole divisor of its refresh that is ≥ 60 fps:
144 Hz → 72, 120 Hz → 120), and the main window becomes a preview with the controls and HUD. **Output > Stop Output
Display** returns to normal. If the output screen is unplugged, the output closes and the main window renders again by
itself. With one display, the output window opens as a normal-level fullscreen window so you can still Cmd-Tab back.
CLI: `--output-screen N` (screen numbers are listed in the log at startup).

## MIDI control

Every connected MIDI input is used (devices plugged in later are picked up automatically).

**Controls > MIDI Learn…** (⌘L): move a knob, fader or pad, then click the target it should drive. Click ✕ to unmap.
If you click a target before moving anything, the next control you move is bound to it.

| Target | Knob / fader (CC) | Pad / key (note) |
|---|---|---|
| Mode next / previous | fires when pushed past half | fires on press |
| Preset next / previous | 〃 | 〃 |
| Intensity | Chill / Normal / Wild by position | cycles |
| Master brightness | 0–100 % | toggles 0 / 100 % |
| Strobe | on above half | strobe while held |
| Blackout | toggles when pushed past half | toggles |
| Tap tempo, BPM ±0.1, beat nudge ±10 ms, auto-cycle on/off | fires when pushed past half | fires on press |

The strobe from MIDI goes through the same photosensitivity limiter as the automatic strobe: at most 3 flashes per second
unless you lift the limit with Shift-S (warning shown), and nothing flashes while strobes are off (S).

Mappings are saved to `~/Library/Application Support/RAVE LIVE/midi-mappings.json`. **Controls > Export / Import MIDI
Mappings…** move them between machines. Format:

```json
{ "version": 1, "clockSync": true,
  "mappings": [ { "control": { "kind": "cc", "channel": 0, "number": 1 }, "action": "intensity" },
                { "control": { "kind": "note", "channel": 9, "number": 36 }, "action": "presetNext" } ] }
```

Actions: `modeNext modePrev presetNext presetPrev intensity brightness strobe blackout tapTempo nudgeEarlier nudgeLater
bpmUp bpmDown autoCycle`. Channels are 0-based (0 = MIDI channel 1).

### MIDI clock

**Controls > Sync to MIDI Clock** (on by default): while a 24 ppqn MIDI clock is running (from a DAW, a DJ app or
hardware), its tempo replaces the audio tempo tracker; when the clock stops, the audio tracker takes over again. Tempo
is a least-squares fit over the last 8 beats of ticks, so it reads steady but takes about 4 s to settle after a big tempo
jump. Only the tempo comes from the clock; the beat phase still locks to the audio.

Test harness: `swiftc -O scripts/midi_harness.swift -o build/midi_harness && build/midi_harness` creates a virtual
controller and sends CCs, notes and clock (128 BPM, then 100 BPM). Launch the app with
`--midi-map <file> --midi-log <file>` to keep your own mappings untouched and log what fires.

## Control HUD and cheat sheet

**H** cycles the on-screen text: status line + mode bar → full Control HUD (top right: mode, preset, BPM and its source
(LOCKED / MIDI CLOCK / TAP / searching), intensity, brightness/blackout/strobe state, audio source, Syphon and MIDI
status, and where the output goes) → off (clean picture, no text or mode bar) → back to the status line. The level you
pick is remembered; set it in **Settings (⌘,)** or **Output > HUD** too. **?** shows the keyboard cheat sheet. Both are performer-only: they are
not on Syphon or the output display.

## Lyrics and the Now Playing card

RAVE LIVE can show synced lyrics for whatever your Mac reports as Now Playing (Spotify, Music, browsers, most players),
and a small player card bottom left with artwork, title, artist, the source app, progress and previous / play-pause / next.

- **Lyrics are off until you turn them on** (Settings → Lyrics switch, or **Y**; the switch follows the key): while on, the playing track's title, artist,
  album and length are looked up on [lrclib.net](https://lrclib.net), a free lyrics database. Results are cached on your Mac
  (`~/Library/Application Support/RAVE LIVE/Lyrics`).
- **Remixes, edits, bootlegs, VIPs, flips, mashups and sped-up / slowed / nightcore / 8D versions get no lyrics** (and are never looked up): original-song timing
  doesn't fit them and wrongly timed lyrics look broken. Lyrics also stay off when the track length is more than 3 s
  away from the LRCLIB match.
- **You always see why there are no lyrics.** A small line where the lyrics go (for a few seconds after each change, and
  whenever the mouse moves) and the card say: "Lyrics off (Y)", "Looking up lyrics…", "No synced lyrics found",
  "Lyrics server busy, retrying", "Lyrics offline, retrying", "Skipped: remix/edit", "Skipped: video length 4:50 doesn't
  match the song (2:41)", "Skipped: long video/mix". Every "Skipped" line ends with "Press L to sync anyway".
- **YouTube and other videos in a browser** (Safari, Chrome, Zen, Arc, Brave, Firefox, Edge…): the title is cleaned
  ("(Official Video)", "[Official Music Video]", "(Lyrics)", "ft. …", "| …" tails), "Artist - Title" is split, and the
  channel ("Artist - Topic", "ArtistVEVO") is the artist otherwise. A music video up to 90 s longer than the song syncs
  with that much intro assumed; anything over twice the song's length is treated as a long video or mix and skipped.
- **L** syncs a skipped song anyway (from the start of the video) and **L** again undoes it; in MILKDROP, where L locks
  the preset, use **Shift-L**. **Shift -** / **Shift =** move the lyrics 1 s for the current song (not saved).
- Full HUD (**H** twice) adds a "Lyrics" row: source app, the title and artist that were looked up, the two lengths
  compared and the decision. Tell us that line when lyrics look wrong.
- When lrclib.net is overloaded (503) or rate-limits (429), RAVE LIVE backs off (honouring `Retry-After`, with jitter),
  tries `/api/search` when `/api/get` fails, and retries the song after 10 s, 20 s, 40 s … up to 10 min.
- **Styles** (Settings → Lyrics style, or **Shift-Y** to cycle). Every style reacts to the music RAVE LIVE hears, not
  just to the clock: the beat, the kick, the bass and the energy.
  - **Clean** (default): white, calm. Words not sung yet are dimmed, each word brightens and lifts a little as it is sung,
    the line breathes on the beat.
  - **Neon karaoke**: a magenta → cyan fill sweeps through each word as it is sung; the glow follows the song's energy
    and swells on the beat.
  - **Pop**: one to three big words at a time (CapCut-style), each springing in as it is sung; kicks punch them.
  - **Bass wave**: the letters ride a wave whose height follows the bass, and every kick sends a ripple from the word
    being sung.
  - **Spectrum**: every word is an equaliser bar, its height driven by its own frequency band (low on the left).
  - **Auto**: Clean when it's quiet, Bass wave or Neon as the energy builds, Pop on drops (it cuts in on the drop and
    rides it for 16 s); otherwise it only changes between lines.
- **Word by word**: lyrics with word timing (enhanced LRC) use it. Most LRCLIB lyrics only time whole lines, so the
  words are spread over the line by syllables and then snapped to the live beat grid (8th notes) when they are already
  close, which is where sung words land.
- Position: **Lower third** (default) or **Centre**; size Small / Medium / Large. No box or shade behind the text: every
  letter has a thin dark outline and a tight shadow, so it reads on white frames too. Lines never overlap: the old line
  fades out (0.12 s) before the new one fades in.
- **Strobe effects off** (Settings, or **S**) also calms the lyrics: glows and brightness can't change faster than a
  full swing in 0.4 s, and kicks punch half as hard.
- Lines go up 150 ms before they are sung, so reading keeps up with the singer. The player's own position is used as
  it is: players already count the Bluetooth/AirPlay delay, so it is not subtracted again (that made lyrics late on
  Bluetooth headphones). **-** / **=** move the lyrics 50 ms earlier / later, or use the Lyrics timing slider (±1000 ms).
- The card hides a few seconds after the mouse stops moving; **N** turns it off. HUD off (clean picture) hides both.
- Like the HUD, lyrics and the card are on the main window only, never on Syphon or the output display (a follow-up may
  add lyrics to the output).
- "Lyrics offline" means no network or a Wi-Fi login page (retried after 30 s, then less often, up to every 10 min).
- There is no second lyrics source: we found no other synced-lyrics service that is free, needs no API key and allows
  this use in its terms (the others need a key, or are unofficial scrapes of NetEase, QQ Music, Musixmatch or Spotify).
- Now Playing is read by the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause)
  through `/usr/bin/perl`, because macOS only lets Apple-signed processes read it. Builds without it
  (`scripts/build_mediaremote_adapter.sh`) run as before and Settings explains why lyrics and the card are off.

## Keyboard shortcuts

| Key | Action |
|---|---|
| V | next mode |
| ⌘1 … ⌘5 | SHOW / Stage / Classic Visuals / AURORA / MILKDROP |
| ] / [ | next / previous preset (Classic; in MILKDROP the MilkDrop preset) |
| 1 … 8 | preset (Classic) or Stage look; in MILKDROP 1–5 rate the preset, 0 clears |
| A | auto-cycle presets on/off |
| I | intensity Chill / Normal / Wild |
| B | blackout |
| S | strobe on/off |
| Shift-S | lift / restore the 3 flashes per second limit |
| T | tap tempo |
| Shift-T, ⇧⌘T | Tweak panel (Classic Visuals) |
| ⌘S / ⌘O | save / open a `.ravelook` |
| ← / → | BPM −0.1 / +0.1 (with Shift: 1); inside the open Tweak panel ←→ change a value |
| , / . | beat nudge: visuals 10 ms earlier / later |
| M | system audio ↔ the last input device |
| C, ⌘K | camera hands & body (AURORA) |
| F, ⌘F | fullscreen (Esc exits), in every mode |
| P, ⌘P | MilkDrop preset browser (P again closes it) |
| R | MILKDROP: random preset · open Tweak panel: reset the preset |
| L | MILKDROP: lock the preset (no automatic changes) |
| Shift-F | MILKDROP: favourite the preset |
| H | HUD: status → full → off |
| ⌘, | Settings… |
| ? | cheat sheet |
| ⌘L | MIDI Learn… |
| Y | synced lyrics on/off |
| N | Now Playing card on/off |
| - / = | lyrics 50 ms earlier / later |
| Shift - / Shift = | lyrics 1 s earlier / later for this song |
| L | sync lyrics anyway / undo (Shift-L in MILKDROP) |

In MILKDROP mode the MIDI targets *Preset next / previous* step MilkDrop presets and *Auto-cycle* toggles the preset lock.

## Test flags

`--syphon`, `--output-screen N`, `--hud`, `--midi-map PATH`, `--midi-log PATH`, `--midi-learn ACTION`, `--no-midi`, and
`--vjscript "t:cmd,…"` for scripted UI checks (`hud`, `cheat`, `learn`, `output=N`, `stopoutput`, `unplug` (simulated),
`syphon`, `brightness=0.5`, `shot=NAME` main window incl. overlays, `outshot=NAME` output frame, `learnshot=NAME`,
`card` show the player card, `cardplay` click its play/pause button, `lyricsnow=TAG` log position and lyric line).
Env `RAVE_MTKVIEW_TIMER=1` draws from MTKView's own timer instead of the display link of the screen the window is on
(macOS 14+), for A/B frame-pacing tests.

Lyrics flags: `--lyrics` / `--no-lyrics`, `--player-card` / `--no-player-card`, `--lyrics-offset MS`, `--lyrics-size 0-2`,
`--lyrics-log PATH`. Env: `RAVE_LRCLIB_HOST` (another LRCLIB server, or a bad host to test the offline state),
`RAVE_LYRICS_CACHE` (cache folder), `RAVE_MEDIAREMOTE_DIR` (adapter folder, e.g. `vendor/mediaremote-adapter`).
