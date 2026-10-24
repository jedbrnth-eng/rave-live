#!/usr/bin/env python3
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

"""Score RAVE LIVE's streaming beat/downbeat tracker against Beat This! ground truth.
For each track: run rave-probe on 0..CLIP s (same code path as live), then compute
  - beat F-measure (+-70 ms, MIREX standard), after the tracker's first 8 s
  - signed offset of matched beats (ms; + = our beat is late)
  - downbeat accuracy: share of our beats labelled beat-1 that land on a true downbeat (+-70 ms)
Octave note: if we track double/half time, F drops; we also report F vs the best metrical level."""
import json, os, subprocess, sys, glob
import numpy as np
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
probe = os.path.join(root, ".build/release/rave-probe")
CLIP = os.environ.get("RAVE_CLIP", "90"); WARM = 8.0; TOL = 0.07

def fmeasure(est, ref):
    if len(est) == 0 or len(ref) == 0: return 0.0, []
    used = set(); offs = []
    for e in est:
        j = int(np.argmin(np.abs(ref - e)))
        if abs(ref[j] - e) <= TOL and j not in used: used.add(j); offs.append(e - ref[j])
    p = len(offs) / len(est); r = len(offs) / len(ref)
    return (2 * p * r / (p + r) if p + r else 0.0), offs

rows = []
for gt in sorted(glob.glob(os.path.join(root, os.environ.get("GT_DIR", "tools/gt"), "*.json"))):
    g = json.load(open(gt)); f = os.path.expanduser(g["file"])
    if not os.path.exists(f): print("SKIP (audio file missing):", os.path.basename(gt)); continue
    out = f"/tmp/rl_eval_{os.environ.get('EVAL_TAG', '')}_{os.path.basename(gt)}"
    env = dict(os.environ, RAVE_BEATS_OUT=out, RAVE_CLIP=CLIP)
    pr = subprocess.run([probe, "file", f, str(g["bpm"]), "0"], env=env, capture_output=True, text=True, timeout=600)
    refl = [l for l in pr.stdout.splitlines() if l.startswith("REFEREE")]
    if refl and os.environ.get("VERBOSE"): print("  ", os.path.basename(f)[:30], refl[0])
    r = json.load(open(out))
    est = np.array(r["beats"]); bib = np.array(r["beatInBar"])
    keep = est >= WARM; est, bib = est[keep], bib[keep]
    ref = np.array(g["beats"]); ref = ref[(ref >= WARM) & (ref <= float(CLIP))]
    dref = np.array(g["downbeats"]); dref = dref[(dref >= WARM) & (dref <= float(CLIP))]
    F, offs = fmeasure(est, ref)
    # best metrical level (double / half of the reference)
    dbl = np.sort(np.concatenate([ref, (ref[:-1] + ref[1:]) / 2])); half = ref[::2]
    Fbest = max(F, fmeasure(est, dbl)[0], fmeasure(est, half)[0], fmeasure(est, ref[1::2])[0])
    ests_down = est[bib == 0]
    down_hit = np.mean([np.min(np.abs(dref - d)) <= TOL for d in ests_down]) if len(ests_down) and len(dref) else 0.0
    rows.append((os.path.basename(f)[:34], g["bpm"], F, Fbest, np.mean(offs) * 1000 if offs else np.nan,
                 np.std(offs) * 1000 if offs else np.nan, down_hit))
print(f"{'track':34s} {'gtBPM':>6s} {'F':>5s} {'Fbest':>5s} {'off_ms':>7s} {'jit_ms':>6s} {'down%':>6s}")
for t in rows: print(f"{t[0]:34s} {t[1]:6.1f} {t[2]:5.2f} {t[3]:5.2f} {t[4]:7.1f} {t[5]:6.1f} {t[6]*100:6.0f}")
a = np.array([[t[2], t[3], t[4], t[5], t[6]] for t in rows], dtype=float)
print(f"{'MEAN':34s} {'':6s} {np.nanmean(a[:,0]):5.2f} {np.nanmean(a[:,1]):5.2f} {np.nanmean(a[:,2]):7.1f} {np.nanmean(a[:,3]):6.1f} {np.nanmean(a[:,4])*100:6.0f}")
