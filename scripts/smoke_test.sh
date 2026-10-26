#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Headless smoke test: runs the built app for a few seconds on synthetic audio (nothing is played) and checks
# that a rendered snapshot isn't black. Skips with exit 0 and a clear message when there is no Metal device
# (CI virtual machines often have no GPU). Usage: scripts/smoke_test.sh ["path/to/RAVE LIVE.app"]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/RAVE LIVE.app}"
OUT="${SMOKE_OUT:-build/smoke}"
EXE="$APP/Contents/MacOS/RaveLive"
[ -x "$EXE" ] || { echo "smoke: $EXE not found. Run scripts/make_app.sh first." >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"

# Tiny helper: "gpu" prints the Metal device (exit 1 if none); "<png>" prints the snapshot's mean brightness 0-255.
cat > "$OUT/check.swift" <<'SWIFT'
import AppKit
import Metal
let a = CommandLine.arguments
if a.count < 2 || a[1] == "gpu" {
    guard let d = MTLCreateSystemDefaultDevice() else { print("none"); exit(1) }
    print("\(d.name) (lowPower \(d.isLowPower), apple7 \(d.supportsFamily(.apple7)))"); exit(0)
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("unreadable"); exit(1) }
let w = 64, h = 36
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
var sum = 0.0
for i in 0..<(w * h) { sum += 0.299 * Double(px[i * 4]) + 0.587 * Double(px[i * 4 + 1]) + 0.114 * Double(px[i * 4 + 2]) }
print(String(format: "%.2f", sum / Double(w * h)))
SWIFT
swiftc -O "$OUT/check.swift" -o "$OUT/check" 2>/dev/null

if ! GPU="$("$OUT/check" gpu)"; then
  echo "smoke: SKIPPED - no Metal device on this machine ($(uname -m), macOS $(sw_vers -productVersion)), so the renderer can't run here."
  exit 0
fi
echo "smoke: Metal device: $GPU"

# Stage mode is bright from the first second, so a black frame really means nothing rendered.
set +e
perl -e 'alarm 90; exec @ARGV' "$EXE" --accept-warning --demo --no-referee --stage --autoquit 8 --snap 4 \
  --snapdir "$OUT" --metrics "$PWD/$OUT/metrics.json" --width 640 --height 360 > "$OUT/log.txt" 2>&1
STATUS=$?
set -e
grep -E "RAVE LIVE: (quality|analyzer)|Shader error" "$OUT/log.txt" || true
[ "$STATUS" -eq 0 ] || { echo "smoke: app exited with status $STATUS"; tail -20 "$OUT/log.txt"; exit 1; }
SNAP="$(ls "$OUT"/snap_*.png 2>/dev/null | head -1)"
[ -n "$SNAP" ] || { echo "smoke: no snapshot written"; tail -20 "$OUT/log.txt"; exit 1; }
LUMA="$("$OUT/check" "$SNAP")"
echo "smoke: $SNAP mean brightness $LUMA / 255"
awk -v l="$LUMA" 'BEGIN { exit !(l > 3) }' || { echo "smoke: snapshot is black"; exit 1; }
echo "smoke: OK"
