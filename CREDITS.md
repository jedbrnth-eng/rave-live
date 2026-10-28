# Credits and licences

- **Beat This!** (CPJKU, MIT licence) — https://github.com/CPJKU/beat_this — used two ways:
  1. `tools/ground_truth.py`: offline ground-truth beats/downbeats for `tools/eval_sync.py`.
  2. `tools/referee.py`: live "referee" sidecar (CPU, ~110 ms per 12 s window every 1.5 s) that corrects the
     app's causal tracker (off-beat phase, tempo level, bar line). Optional: the app runs without it.
  Paper: Foscarin, Schlüter, Widmer, "Beat this! Accurate beat tracking without DBN postprocessing", ISMIR 2024.
- **WebGL-Fluid-Simulation** (Pavel Dobryakov, MIT) — AURORA's fluid solver follows its structure and is re-implemented in Metal.
  Copyright (c) 2017 Pavel Dobryakov. Permission is hereby granted, free of charge, under the MIT License (full text at
  https://github.com/PavelDoGreat/WebGL-Fluid-Simulation/blob/master/LICENSE).
- **Apollonian fractal / cosine palettes** — formulations published by Inigo Quilez (re-implemented).
- **Visuals pack 1 (presets 23-31)** — techniques re-implemented from scratch, no Shadertoy code copied: Gray-Scott reaction-diffusion
  (Pearson 1993 parameters; the Du=1.0 / Dv=0.5 nine-point-stencil formulation described by Karl Sims, "Reaction-Diffusion Tutorial"),
  damped 2D wave equation (Pond), curl-of-potential advection (Ink Water), Vogel/golden-angle phyllotaxis (Flower),
  box-grid distance-field marching with a cell-exit bound (Neon City), ridged heightfield marching (Terrain),
  radial firework shells (Fireworks). Concept frames for the presets were AI-generated reference images (used only as a visual reference, not shipped).
- **Syphon-Framework** (bangnoise / Tom Butterworth & vade / Anton Marini; Metal server by Maxime Touroute & Philippe Chaurand,
  BSD-3-Clause) — https://github.com/Syphon/Syphon-Framework — optional Syphon output. Built from source commit
  f4761677a45b8034a3c2069ec0f3d2553da81fba by `scripts/build_syphon.sh` (not vendored in git); the licence text ships inside the
  bundled framework (`Syphon.framework/Resources/License.txt`). BSD-3-Clause is GPL-3.0 compatible.
- **Visuals pack 3 (presets 33-47) and Shader Lab** — re-implemented from scratch, no third-party code: Julia sets with the
  smooth iteration count (Inigo Quilez's published formulation), Conway's Game of Life (1970), times-table "string art"
  (Mathologer-style modular multiplication circle), goniometer / XY vectorscope plotting, cell-exit box marching (as Neon City).
  Shader Lab's `palette()` helper is Inigo Quilez's cosine palette formula. The example shaders in `community/shaders/` are CC0-1.0.
- **projectM** (projectM team, LGPL-2.1-or-later) — https://github.com/projectM-visualizer/projectm — the MilkDrop engine
  behind MILKDROP mode. Version 4.1.8, built from the release source by `scripts/build_projectm.sh` with one small patch
  (`scripts/projectm-patches/0001-render-frame-to-fbo.patch`, same licence: render into a caller-supplied framebuffer).
  Shipped as a separate dynamic library (`RAVE LIVE.app/Contents/Frameworks/libprojectM-4.dylib`) that RAVE LIVE loads at
  runtime, so it can be replaced with any compatible build. Licence text: https://github.com/projectM-visualizer/projectm/blob/master/COPYING
  (also in the source tarball); corresponding source = the pinned upstream tarball + the patch above. projectM bundles
  projectm-eval (MIT), GLM (MIT), SOIL2 (MIT-0/public domain) and hlslparser (MIT).
- **MilkDrop presets** — 149 presets from projectM's "cream of the crop" pack
  (https://github.com/projectM-visualizer/presets-cream-of-the-crop, commit 0180df21f5e0bd39b9060cc5de420ed2f1f9e509) ship
  inside the app (list with SHA-256 per file: `Resources/MilkDrop/bundled.txt`; fetched by `scripts/fetch_milkdrop_presets.sh`,
  not committed). The pack's LICENSE.md and an AUTHORS.txt are copied next to them in the app. Most MilkDrop presets were
  released without a licence; the projectM team treats them as public domain (assumed public domain) and removes presets on
  an author's request, and so will we. "Get 9,800 More Presets…" downloads the full pack on the user's click.
  Authors of the bundled presets, as named in the file names: PieturP, TonyMilkdrop, Phat_shifter, Mstress, phat + EoS, beta106i, Tripgnosis, ORB, yin, Zylot, Waltra, Martin N AdamFX Infusion = Phat+Yin+EoS_Mandala Chaser Ft AdamFX n Martin, Geiss, suksma, mddb-rar bdrv, martin, fiShbRaiN, amandio c, Syst3mFailur, Serge + martin, LuxXx, Krash & yin, Jc, Flexi, EoS + Phat, EoS, EVET, Adam Eatit Mashup FX 2 martin, $$$ Royal, whoraeckle', va ultramix2, shifter, rce-ordinary + flexi, rarian rakista, phat_CloseIncouneters_update EoS tweak, i poison my plants with my piss, hexcollie, ti@n, suksma, zylot, orb n flexi, hexcollie, goody(2),stahlregen (2),fed, goody(2), stahlregen (2), goody + martin, goody + geiss , geiss_experimental__Spiral Artifact (Filament Mix), flexi, extreme paranoia and fear unleash in spontaneous suicide flails, drugsincombat, cope + flexi, beta106S + Phat, bdrv + al EoS, The NG + martin + Flexi, The NG + flexi + bdrv, Telek & EMPR, Telek, Starz in MilkHDFX, Stahlregen & Geiss + TobiasWolfBoi, Stahlregen & Geiss + Rovastar, Stahlregen & Aderrasi + Flexi + Rovastar, Stahlregen, Serge + Jc, Rovastar & StudioMusic, Rovastar & Krash, Rovastar, Reenen & Telek, Redi Jedi, Pithlit, Phat_Aderrasi, Phat+Yin+EoS_Mandala_Chasers_SOULar_Named_Red_Pulse_b, Phat + EoS, Ondras, Milk King to the ExtreemFX flexi, Milk Artist At our Best, LuX, Krash and Fvese, Krash & yin + Phat, Infused by Flexi with AdamFX 2 Stahlregen & Aderrasi + EoS + Geiss + Unchained + Zylot, Illusion & Unchained, Hexcollie n EoS, Hexcollie, Halfbreak, Goody's Fatal Color Attraction PS2-0, Goody + martin, Flexi bdrv, EvilJim, Esotic vs Rozzor, Dark One, Cope-WIP, Cope, Blastofftek, Benski, Benjam and Zylot, Aderrasi, AdamFX Enterz Tha Mash With Martin + stahlregen, A Tribute to Martin, 3dRaGoNs & Rovastar.
- **mediaremote-adapter** (Jonas van den Berg and contributors, BSD-3-Clause) — https://github.com/ungive/mediaremote-adapter —
  reads macOS Now Playing (title, artist, position, artwork) and sends play/pause/next/previous for the lyrics overlay and the
  player card. Built from tag v0.7.7 (commit e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6) by `scripts/build_mediaremote_adapter.sh`
  (not vendored in git). Shipped as `Contents/Frameworks/MediaRemoteAdapter.framework` (not linked; loaded by `/usr/bin/perl`)
  plus its `mediaremote-adapter.pl` script; the licence text ships next to the script
  (`Contents/Resources/MediaRemoteAdapter/LICENSE.txt`). BSD-3-Clause is GPL-3.0 compatible. Optional: the app runs without it.
- **LRCLIB** (https://lrclib.net) — free synced-lyrics database, queried at runtime only when lyrics are switched on. No lyrics
  are stored in this repository; fetched lyrics are cached on the user's Mac (`~/Library/Application Support/RAVE LIVE/Lyrics`).
  The LRC parser is our own (a ~60-line format; reusing a Swift LRC library would add a dependency for less code than its glue).
- Checked and not used (licence): aubio (GPL-3), BTrack (GPL-3), Essentia (AGPL-3), madmom (licence unclear),
  BeatNet (CC-BY-4.0, Python real-time downbeat model; considered, Beat This! measured better as referee).
