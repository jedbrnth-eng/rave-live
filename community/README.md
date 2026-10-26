# RAVE LIVE community visuals

This folder collects Shader Lab shaders (`.metal`) and look presets (`.ravelook`) made by RAVE LIVE users. The app
ships the shaders in `shaders/` as examples and copies them into your Shader Lab folder on first launch. A later
version can read `index.json` to offer the whole collection in the app.

How to make one: [docs/SHADERS.md](../docs/SHADERS.md) (5-minute tutorial).

## Layout

```
community/
  index.json             # list of every contribution (the app reads this later)
  shaders/<name>.metal   # Shader Lab shaders: lowercase_with_underscores, one visual per file
  shaders/_template.metal
  looks/<name>.ravelook  # look presets (a built-in preset + tweaks, or a shader here + tweaks)
```

## Send yours (pull request)

1. Fork the repo and add your file to `community/shaders/` or `community/looks/`.
2. At the top of a shader, add a comment with its name, a one-line description, your name or handle, and the line
   `// SPDX-License-Identifier: GPL-3.0-or-later` (see below).
3. Add an entry to `index.json` (copy an existing one).
4. In the PR, attach a screenshot or a short clip, and say which music you tested it with.
5. Checklist:
   - It compiles in Shader Lab without errors, on the current release.
   - It runs smoothly (no drop below 60 fps) on your Mac. Say which Mac.
   - It moves with the beat (`r.beat`, `beatPulse`, `floor(r.beat)`), not just with `r.time`.
   - No full-screen flashing faster than 3 times a second. RAVE LIVE has a photosensitivity limit, and contributions
     must respect it.
   - No Apple-GPU-only features (it has to run on Intel and AMD Macs too).
   - The code is yours, or you have the right to share it under GPL-3.0-or-later. Shadertoy code is often
     "all rights reserved" or CC BY-NC-SA: don't submit it unless the author's licence allows that, and keep their
     credit.

## Licence for contributions

Shaders and looks contributed here are licensed under **GPL-3.0-or-later**: everyone can use, change and share them,
and changed versions that are shared stay open under the same terms. Put this line at the top of every file you send
(looks: in the `license` field of `index.json`):

```
// SPDX-License-Identifier: GPL-3.0-or-later
```

You keep the copyright on your work; the licence is what lets RAVE LIVE ship it and others build on it. Files without
the SPDX line won't be merged. The example shaders that ship with the app (marked "example shipped with RAVE LIVE") are
CC0, so you can start your own shader from one without any conditions. The app itself is GPL-3.0 (see
[LICENSE](../LICENSE)).

## index.json

```json
{
  "version": 1,
  "items": [
    { "type": "shader", "file": "shaders/pulse_rings.metal", "name": "Pulse Rings", "author": "RAVE LIVE",
      "license": "GPL-3.0-or-later", "description": "...", "tags": ["beat", "rings"] }
  ]
}
```

`type` is `shader` or `look`. `file` is relative to `community/`. `tags` are free-form lowercase words.
