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

- **Lyrics are off until you turn them on** (Settings → Lyrics, or **Y**): while on, the playing track's title, artist,
  album and length are looked up on [lrclib.net](https://lrclib.net), a free lyrics database. Results are cached on your Mac
  (`~/Library/Application Support/RAVE LIVE/Lyrics`).
- **Remixes, edits, bootlegs, VIPs, flips, mashups and sped-up / slowed / nightcore / 8D versions get no lyrics** (and are never looked up): original-song timing
  doesn't fit them and wrongly timed lyrics look broken. Lyrics also stay off when the track length is more than 3 s
  away from the LRCLIB match. The card then says "lyrics off: remix/edit" (or "lyrics off: other version" for a length mismatch).
- The current line sits large and low in the middle, the next line smaller below it; lines crossfade and breathe very
  gently on the beat (no flashing). Timing follows the audio output latency (Bluetooth, AirPlay); **-** / **=** move the
  lyrics 50 ms earlier / later, or use the Lyrics timing slider (±1000 ms). Size: Settings → Lyrics size.
- The card hides a few seconds after the mouse stops moving; **N** turns it off. HUD off (clean picture) hides both.
- Like the HUD, lyrics and the card are on the main window only, never on Syphon or the output display (a follow-up may
  add lyrics to the output).
- Card notes: "lyrics offline" (no network, LRCLIB down, or a Wi-Fi login page; retried after 30 s, then less often, up to every 10 min), "instrumental", "no synced lyrics".
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

In MILKDROP mode the MIDI targets *Preset next / previous* step MilkDrop presets and *Auto-cycle* toggles the preset lock.

## Test flags

`--syphon`, `--output-screen N`, `--hud`, `--midi-map PATH`, `--midi-log PATH`, `--midi-learn ACTION`, `--no-midi`, and
`--vjscript "t:cmd,…"` for scripted UI checks (`hud`, `cheat`, `learn`, `output=N`, `stopoutput`, `unplug` (simulated),
`syphon`, `brightness=0.5`, `shot=NAME` main window incl. overlays, `outshot=NAME` output frame, `learnshot=NAME`,
`card` show the player card, `cardplay` click its play/pause button, `lyricsnow=TAG` log position and lyric line).

Lyrics flags: `--lyrics` / `--no-lyrics`, `--player-card` / `--no-player-card`, `--lyrics-offset MS`, `--lyrics-size 0-2`,
`--lyrics-log PATH`. Env: `RAVE_LRCLIB_HOST` (another LRCLIB server, or a bad host to test the offline state),
`RAVE_LYRICS_CACHE` (cache folder), `RAVE_MEDIAREMOTE_DIR` (adapter folder, e.g. `vendor/mediaremote-adapter`).
