#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Builds the universal Syphon test client (needs vendor/Syphon.framework from build_syphon.sh) and runs it
# against a running RAVE LIVE with Output > Syphon on (or --syphon). Usage: syphon_client.sh [seconds] [out.png] [arch]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=build/syphon_client
mkdir -p build
if [ ! -x "$BIN" ] || [ scripts/syphon_client.swift -nt "$BIN" ]; then
  for a in arm64 x86_64; do
    swiftc -O -target $a-apple-macos12.0 -F vendor -framework Syphon -Xlinker -rpath -Xlinker "$PWD/vendor" \
      scripts/syphon_client.swift -o "$BIN.$a"
  done
  lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN" && rm -f "$BIN.arm64" "$BIN.x86_64"
fi
if [ "${3:-}" = "x86_64" ]; then exec arch -x86_64 "$BIN" "${1:-4}" "${2:-syphon_frame.png}"; fi
exec "$BIN" "${1:-4}" "${2:-syphon_frame.png}"
