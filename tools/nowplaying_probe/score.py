# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live
"""Now Playing position minus the page currentTime, per sample. Usage: score.py <dir with page.jsonl np.jsonl>."""
import json, sys
d = sys.argv[1] if len(sys.argv) > 1 else "."
st = {}
anchors = []  # (recv, elapsed, ts, rate, playing) after applying diff, mimicking NowPlayingStream
for line in open(f"{d}/np.jsonl"):
    recv, js = line.split("\t", 1)
    p = json.loads(js)["payload"]
    if not json.loads(js)["diff"]:
        st = {}
    st.update(p)
    if st.get("title") != "SyncProbe Tone" and "title" in st:
        continue
    if "elapsedTimeMicros" in st:
        anchors.append((float(recv), st["elapsedTimeMicros"] / 1e6, st.get("timestampEpochMicros", 0) / 1e6,
                        st.get("playbackRate", 0), st.get("playing", False)))

def pos(t):
    a = None
    for x in anchors:
        if x[0] <= t: a = x
    if not a: return None
    recv, el, ts, rate, playing = a
    if not playing: return el
    return el + (t - ts) * (rate if rate > 0 else 1)

rows = []
for line in open(f"{d}/page.jsonl"):
    e = json.loads(line)
    if e["ev"] != "tick" or e["paused"]: continue
    p = pos(e["t"])
    if p is None: continue
    rows.append((e["t"], e["ct"], p - e["ct"]))
t0 = rows[0][0]
for t, ct, diff in rows[::10]:
    print(f"t+{t-t0:6.1f}s page={ct:7.3f}  nowplaying-page={diff*1000:+8.1f} ms")
ds = [r[2]*1000 for r in rows]
print("n", len(ds), "min %.1f max %.1f mean %.1f" % (min(ds), max(ds), sum(ds)/len(ds)))
