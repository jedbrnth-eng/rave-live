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
- Checked and not used (licence): aubio (GPL-3), BTrack (GPL-3), Essentia (AGPL-3), madmom (licence unclear),
  BeatNet (CC-BY-4.0, Python real-time downbeat model; considered, Beat This! measured better as referee).
- **projectM** (projectM team, LGPL-2.1-or-later) — https://github.com/projectM-visualizer/projectm — the MilkDrop engine
  behind MILKDROP mode. Version 4.1.8, built from the release source by `scripts/build_projectm.sh` with one small patch
  (`scripts/projectm-patches/0001-render-frame-to-fbo.patch`, same licence: render into a caller-supplied framebuffer).
  Shipped as a separate dynamic library (`RAVE LIVE.app/Contents/Frameworks/libprojectM-4.dylib`) that RAVE LIVE loads at
  runtime, so it can be replaced with any compatible build. Licence text: https://github.com/projectM-visualizer/projectm/blob/master/COPYING
  (also in the source tarball); corresponding source = the pinned upstream tarball + the patch above. projectM bundles
  projectm-eval (MIT), GLM (MIT), SOIL2 (MIT-0/public domain) and hlslparser (MIT).
- **MilkDrop presets** — not bundled. "Get MilkDrop presets…" downloads projectM's "cream of the crop" pack
  (https://github.com/projectM-visualizer/presets-cream-of-the-crop) on the user's click. Most presets were released
  without a licence; projectM treats them as public domain and removes presets on the author's request.
