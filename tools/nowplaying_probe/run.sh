#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live
# usage: run.sh [seconds]  -- see README.md. Silent: the page plays at element volume 0.001.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/np-probe}"; SECS=${1:-55}
mkdir -p "$OUT/profile"; cp "$HERE/user.js" "$OUT/profile/user.js"; rm -f "$OUT"/profile/sessionstore*
cp "$HERE/page.html" "$OUT/"
[ -f "$OUT/tone.wav" ] || ffmpeg -loglevel error -y -f lavfi -i "sine=f=440:d=90" -af "volume=0.3" -ar 44100 "$OUT/tone.wav"
rm -f "$OUT/page.jsonl" "$OUT/np.jsonl"
(cd "$OUT" && exec python3 "$HERE/srv.py" "$OUT/page.jsonl") >/dev/null 2>&1 &
SRV=$!
A="$HOME/Applications/RAVE LIVE.app"
perl -e "alarm $((SECS+5)); exec @ARGV" /usr/bin/perl "$A/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl" \
  "$A/Contents/Frameworks/MediaRemoteAdapter.framework" stream --micros 2>/dev/null \
  | python3 -u -c 'import sys,time
for l in sys.stdin: sys.stdout.write("%.6f\t%s" % (time.time(), l)); sys.stdout.flush()' > "$OUT/np.jsonl" &
NP=$!
sleep 1
/Applications/Zen.app/Contents/MacOS/zen -no-remote -profile "$OUT/profile" "http://127.0.0.1:8765/page.html#nopos" >/dev/null 2>&1 &
ZEN=$!
trap 'kill $ZEN $SRV $NP 2>/dev/null; pkill -f "$OUT/profile" 2>/dev/null' EXIT
sleep "$SECS"
kill $ZEN $SRV $NP 2>/dev/null
sleep 1
python3 "$HERE/score.py" "$OUT"
