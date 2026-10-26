#!/usr/bin/env python3
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live
"""Smoothness report for a `--smoothlog` file (see Sources/RaveLiveApp/SmoothProbe.swift, docs/SMOOTHNESS.md).

usage: smooth_report.py LOG [LOG...] [--json OUT] [--by preset|scene|trans] [--skip SECONDS] [--segment groove|drop|all]

Per group (default: per scene+preset outside transitions, plus one group per transition type):
  frames, fps, flick p95/p99, resid p95/p99, dmean p99, motion p95, jumps (count and per minute),
  glitches (transition frames above the glitch threshold), beat contrast, frame interval p50/p99.
A "jump" is a visible pop: a run of frames whose motion-compensated change (resid) or whole-frame brightness change
(dmean) is above the threshold, starting outside the beat window (phase 0..0.12, where accents belong) and not within
1 s of a drop. Consecutive over-threshold frames count as one jump.
"""
import json
import math
import sys
from collections import defaultdict

# Thresholds (per frame at ~60-72 fps), calibrated in docs/SMOOTHNESS.md.
RESID_JUMP = 0.060     # motion-compensated luma change (0..1): above this off the beat = a visible pop/flash
DMEAN_JUMP = 0.035     # whole-frame mean luma change in one frame: above this off the beat = a flash
GLITCH_DMEAN = 0.10    # one-frame brightness swing during a transition that is a glitch, not a blend
GLITCH_RESID = 0.12    # one-frame structural pop during a transition
BEAT_WINDOW = 0.12
DROP_GRACE = 1.0       # seconds after a drop where big hits are intended


def pct(a, q):
    if not a:
        return float("nan")
    b = sorted(a)
    return b[min(len(b) - 1, int(len(b) * q))]


def load(path, skip):
    rows = []
    with open(path, errors="replace") as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) != len(head):
                continue
            r = dict(zip(head, p))
            try:
                for k in ("t", "dt", "phase", "luma", "dmean", "flick", "resid", "motion", "peak", "kick", "drop", "build"):
                    r[k] = float(r[k])
                r["beat"] = int(r["beat"]); r["locked"] = r["locked"] == "1"
            except ValueError:
                continue
            if r["t"] < skip:
                continue
            rows.append(r)
    return rows


def segment_of(t, period=146 * 60 / 128):
    """Demo timeline (128 BPM, loops every 146 beats): intro 0-15 s, groove 15-30, build 30-37.5, gap, drop 38.4-68.4."""
    x = t % period
    if x < 15: return "intro"
    if x < 30: return "groove"
    if x < 38.4: return "build"
    return "drop"


def beat_contrast(rows):
    """Mean luma per beat-phase bin (8 bins) relative to the mean: (max - min) / mean, and the phase of the peak bin."""
    bins = [[] for _ in range(8)]
    for r in rows:
        if r["locked"]:
            bins[min(7, int(r["phase"] * 8))].append(r["luma"])
    m = [sum(b) / len(b) if b else float("nan") for b in bins]
    good = [x for x in m if not math.isnan(x)]
    if len(good) < 8:
        return float("nan"), -1, m
    mean = sum(good) / 8
    peak = max(range(8), key=lambda i: m[i])
    return (max(good) - min(good)) / max(mean, 1e-4), peak, m


def stats(rows, drops):
    if not rows:
        return None
    flick = [r["flick"] for r in rows]; resid = [r["resid"] for r in rows]; dmean = [r["dmean"] for r in rows]
    motion = [r["motion"] for r in rows]; dts = [r["dt"] for r in rows]
    # a jump = one visible pop: a run of consecutive over-threshold frames counts once (an eased flash spreads
    # over 2-3 frames but is still one event); frames in the beat window or just after a drop don't count
    jumps, inside = 0, False
    for r in rows:
        over = r["resid"] > RESID_JUMP or r["dmean"] > DMEAN_JUMP
        excused = (r["phase"] < BEAT_WINDOW and r["locked"]) or any(0 <= r["t"] - d < DROP_GRACE for d in drops)
        if over and not excused and not inside:
            jumps += 1
        inside = over
    dur = sum(dts)
    c, peak, _ = beat_contrast(rows)
    return {
        "frames": len(rows), "seconds": round(dur, 1), "fps": round(len(rows) / max(dur, 1e-6), 1),
        "luma_mean": round(sum(r["luma"] for r in rows) / len(rows), 3),
        "flick_p95": round(pct(flick, .95), 4), "flick_p99": round(pct(flick, .99), 4),
        "resid_p95": round(pct(resid, .95), 4), "resid_p99": round(pct(resid, .99), 4),
        "dmean_p99": round(pct(dmean, .99), 4), "dmean_max": round(max(dmean), 4),
        "motion_p95": round(pct(motion, .95), 3),
        "jumps": jumps, "jumps_per_min": round(jumps / max(dur / 60, 1e-6), 1),
        "beat_contrast": round(c, 3) if not math.isnan(c) else None, "beat_peak_bin": peak,
        "frame_ms_p50": round(pct(dts, .5) * 1000, 1), "frame_ms_p99": round(pct(dts, .99) * 1000, 1),
    }


def drops_in(rows):
    """Drop starts: the director's drop envelope jumps to ~1."""
    out, prev = [], 0.0
    for r in rows:
        if r["drop"] > 0.95 and prev < 0.9:
            out.append(r["t"])
        prev = r["drop"]
    return out


def transitions(rows):
    """Each transition: its type, the frames it covered, and the glitch frames (big one-frame swings)."""
    out, cur = [], None
    for i, r in enumerate(rows):
        tr = r["trans"]
        if tr == "-":
            if cur:
                # include the first frame after the transition (the hand-over to the plain scene)
                cur["rows"].append(r); out.append(cur); cur = None
            continue
        typ, pair, prog = tr.split(":")
        if cur is None or cur["pair"] != pair or float(prog) + 0.05 < cur["last"]:
            if cur:
                out.append(cur)
            cur = {"type": typ, "pair": pair, "start": r["t"], "rows": [rows[i - 1]] if i else [], "last": 0.0}
        cur["rows"].append(r); cur["last"] = float(prog)
    if cur:
        out.append(cur)
    for t in out:
        rs = t["rows"]
        t["glitches"] = [x["t"] for x in rs[1:] if x["dmean"] > GLITCH_DMEAN or x["resid"] > GLITCH_RESID]
        # the drop flash cut (type flash_cut) is one intended hit on its first frame
        if t["type"] == "flash_cut" and t["glitches"] and t["glitches"][0] - t["start"] < 0.05:
            t["glitches"] = t["glitches"][1:]
        t["frame_ms"] = [x["dt"] * 1000 for x in rs]
    return out


def main(argv):
    paths, out_json, by, skip, seg = [], None, "preset", 3.0, "all"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--json": out_json = argv[i + 1]; i += 2; continue
        if a == "--by": by = argv[i + 1]; i += 2; continue
        if a == "--skip": skip = float(argv[i + 1]); i += 2; continue
        if a == "--segment": seg = argv[i + 1]; i += 2; continue
        paths.append(a); i += 1
    groups = defaultdict(list)
    trans_all = []
    report = {"files": paths, "thresholds": {"resid_jump": RESID_JUMP, "dmean_jump": DMEAN_JUMP, "glitch_dmean": GLITCH_DMEAN, "glitch_resid": GLITCH_RESID}}
    all_drops = []
    for p in paths:
        rows = load(p, skip)
        drops = drops_in(rows); all_drops += drops
        for r in rows:
            if seg != "all" and segment_of(r["t"]) != seg:
                continue
            if r["trans"] != "-":
                continue
            key = r["scene"] + ":" + r["preset"] if by == "preset" else r["scene"] if by == "scene" else "all"
            groups[key].append(r)
        trans_all += transitions(rows)
    report["groups"] = {k: stats(v, all_drops) for k, v in sorted(groups.items())}
    bytype = defaultdict(list)
    for t in trans_all:
        bytype[t["type"]].append(t)
    inside = [ms for t in trans_all for ms in t["frame_ms"]]
    outside = [r["dt"] * 1000 for v in groups.values() for r in v]
    report["transitions"] = {
        typ: {"count": len(ts), "glitch_frames": sum(len(t["glitches"]) for t in ts),
              "dmean_max": round(max(x["dmean"] for t in ts for x in t["rows"][1:]) if ts else 0, 4),
              "resid_max": round(max(x["resid"] for t in ts for x in t["rows"][1:]) if ts else 0, 4),
              "glitch_at": [round(g, 2) for t in ts for g in t["glitches"]][:20]}
        for typ, ts in sorted(bytype.items())}
    report["frame_ms"] = {"in_transitions_p50": round(pct(inside, .5), 1), "in_transitions_p99": round(pct(inside, .99), 1),
                          "outside_p50": round(pct(outside, .5), 1), "outside_p99": round(pct(outside, .99), 1)}
    report["drops"] = [round(d, 2) for d in all_drops]
    # text table
    cols = ["frames", "fps", "luma_mean", "flick_p95", "flick_p99", "resid_p99", "dmean_p99", "motion_p95", "jumps_per_min", "beat_contrast", "beat_peak_bin"]
    print("%-44s " % "group" + " ".join("%9s" % c[:9] for c in cols))
    for k, s in report["groups"].items():
        if s:
            print("%-44s " % k[:44] + " ".join("%9s" % (s[c] if s[c] is not None else "-") for c in cols))
    if report["transitions"]:
        print("\ntransition          count  glitch_frames  dmean_max  resid_max")
        for typ, s in report["transitions"].items():
            print("%-18s %6d %14d %10.4f %10.4f  %s" % (typ, s["count"], s["glitch_frames"], s["dmean_max"], s["resid_max"], s["glitch_at"][:6]))
        print("frame ms in transitions p50/p99 %.1f/%.1f, outside %.1f/%.1f" % (report["frame_ms"]["in_transitions_p50"], report["frame_ms"]["in_transitions_p99"],
                                                                             report["frame_ms"]["outside_p50"], report["frame_ms"]["outside_p99"]))
    if out_json:
        with open(out_json, "w") as f:
            json.dump(report, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
