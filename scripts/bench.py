#!/usr/bin/env python3
"""Run rave-probe on every track in your own list and print a lock-time summary; per-track results go to
bench/results/bench_results_<start>s.json (git-ignored).
Ground truth = the BPM you supply per track (for example your DJ library's analysed BPM; octave conventions can
differ, e.g. hard techno/trap is often tagged at 70-80). Exact-octave and octave-equivalent lock are reported separately."""
import json, subprocess, re, sys, os, concurrent.futures as cf
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
probe = os.path.join(root, ".build/release/rave-probe")
# Your own track list: JSON array of [path (~ allowed), BPM, genre], e.g. exported from a DJ library.
# Pass it as argv[2] or set RAVE_BENCH_TRACKS. No list ships with the repo, and yours is git-ignored.
tracks_file = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else os.environ.get("RAVE_BENCH_TRACKS", ""))
if not tracks_file or not os.path.isfile(tracks_file):
    sys.exit('usage: bench.py [clip_start_seconds] <tracks.json>   (or set RAVE_BENCH_TRACKS)\n'
             'tracks.json = [["/path/to/song.mp3", 128.0, "House"], ...]')
tracks = json.load(open(tracks_file))
start = sys.argv[1] if len(sys.argv) > 1 else "60"

def run(t):
    path, bpm, genre = t
    path = os.path.expanduser(path)
    if bpm < 60:
        return None
    out = subprocess.run([probe, "file", path, str(bpm), start], capture_output=True, text=True, timeout=300).stdout
    m = re.search(r"BENCH final=(\S+) lock_exact=(\S+) lock_x2=(\S+) lock_half=(\S+) conf=(\S+)", out)
    if not m:
        return {"path": path, "truth": bpm, "error": out[-300:]}
    f = lambda s: None if s == "-" else float(s)
    final = float(m.group(1)); le, l2, lh = f(m.group(2)), f(m.group(3)), f(m.group(4))
    octave_lock = min([x for x in (le, l2, lh) if x is not None], default=None)
    return {"path": os.path.basename(path), "genre": genre, "truth": bpm, "final": final,
            "lock_exact": le, "lock_octave_equiv": octave_lock, "conf": float(m.group(5))}

with cf.ThreadPoolExecutor(8) as ex:
    res = [r for r in ex.map(run, tracks) if r]
out_dir = os.path.join(root, "bench", "results"); os.makedirs(out_dir, exist_ok=True)
json.dump(res, open(os.path.join(out_dir, f"bench_results_{start}s.json"), "w"), indent=1)
ok = [r for r in res if "final" in r]
n = len(ok)
exact5 = sum(1 for r in ok if r["lock_exact"] is not None and r["lock_exact"] <= 5)
oct5 = sum(1 for r in ok if r["lock_octave_equiv"] is not None and r["lock_octave_equiv"] <= 5)
octany = sum(1 for r in ok if r["lock_octave_equiv"] is not None)
locks = sorted(r["lock_octave_equiv"] for r in ok if r["lock_octave_equiv"] is not None)
def err(r):
    t = r["truth"]; c = min((t, 2 * t, t / 2), key=lambda x: abs(x - r["final"])); return abs(r["final"] - c)
errs = sorted(err(r) for r in ok if r["lock_octave_equiv"] is not None)
pct = lambda a, q: a[min(len(a) - 1, int(len(a) * q))] if a else float("nan")
print(f"clip start={start}s tracks={n} errors={len(res)-n}")
print(f"exact-octave lock<=5s: {exact5}/{n}   octave-equivalent lock<=5s: {oct5}/{n}   ever locked (any octave): {octany}/{n}")
print(f"lock time p50={pct(locks,.5):.2f}s p90={pct(locks,.9):.2f}s   |error| p50={pct(errs,.5):.2f} p90={pct(errs,.9):.2f} BPM")
bad = [r for r in ok if r["lock_octave_equiv"] is None or r["lock_octave_equiv"] > 5]
for r in bad[:25]:
    print(f"  MISS truth={r['truth']} final={r['final']} lockeq={r['lock_octave_equiv']} conf={r['conf']} {r['path'][:60]}")
