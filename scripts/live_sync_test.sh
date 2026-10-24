#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Live sync test: launches the app (SHOW), plays one file through the speakers after 4 s, quits, and
# guarantees nothing is left playing.  usage: live_sync_test.sh <audio file> [seconds]
set -u
cd "$(dirname "$0")/.."
F="$1"; SECS="${2:-40}"
if pgrep -x afplay >/dev/null; then echo "afplay already running - abort"; exit 1; fi
M=~/.cache/ravelive/m_live_ref.json; rm -f "$M"
( sleep 4; exec afplay -t "$SECS" "$F" ) &   # exec: $PLAYER becomes afplay itself
PLAYER=$!
trap 'kill $PLAYER 2>/dev/null' EXIT
open -n -W "build/RAVE LIVE.app" --args --accept-warning --show --autoquit $((SECS + 6)) --metrics "$M" --width 1920 --height 1080
kill $PLAYER 2>/dev/null; wait $PLAYER 2>/dev/null
pgrep -lx afplay || echo "afplay: none"
python3 - "$M" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["events"]: print(round(e["t"], 1), e["event"])
print(d["sync"]); print(d["state"][:70])
print("fps", round(d["fps_recent"], 1), "p95", round(d["frame_interval_ms"]["p95"], 2), "p99", round(d["frame_interval_ms"]["p99"], 2), "gpu95", round(d["gpu_ms_p95"], 2))
EOF
