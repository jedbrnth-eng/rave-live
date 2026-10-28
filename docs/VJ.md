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
| P, ⌘P | MilkDrop preset browser |
| R | MILKDROP: random preset · open Tweak panel: reset the preset |
| L | MILKDROP: lock the preset (no automatic changes) |
| Shift-F | MILKDROP: favourite the preset |
| H | HUD: status → full → off |
| ⌘, | Settings… |
| ? | cheat sheet |
| ⌘L | MIDI Learn… |

In MILKDROP mode the MIDI targets *Preset next / previous* step MilkDrop presets and *Auto-cycle* toggles the preset lock.

## Test flags

`--syphon`, `--output-screen N`, `--hud`, `--midi-map PATH`, `--midi-log PATH`, `--midi-learn ACTION`, `--no-midi`, and
`--vjscript "t:cmd,…"` for scripted UI checks (`hud`, `cheat`, `learn`, `output=N`, `stopoutput`, `unplug` (simulated),
`syphon`, `brightness=0.5`, `shot=NAME` main window incl. overlays, `outshot=NAME` output frame, `learnshot=NAME`).
