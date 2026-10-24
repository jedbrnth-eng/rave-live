#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Builds build/RAVE-LIVE.dmg: a drag-to-Applications disk image around build/RAVE LIVE.app.
# Run scripts/make_app.sh first. The image is mounted read-only afterwards to check what is inside.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/RAVE LIVE.app"
OUT="build/RAVE-LIVE.dmg"
STAGE="build/dmg-stage"

[ -d "$APP" ] || { echo "$APP not found. Run scripts/make_app.sh first." >&2; exit 1; }

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/RAVE LIVE.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "RAVE LIVE" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "$STAGE"

# Verify: checksum, then mount read-only and confirm the app and the Applications shortcut are really there.
hdiutil verify "$OUT" >/dev/null
MNT="$(mktemp -d)"
cleanup() { hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach "$OUT" -readonly -nobrowse -noverify -mountpoint "$MNT" >/dev/null
[ -d "$MNT/RAVE LIVE.app/Contents/MacOS" ] || { echo "DMG is missing RAVE LIVE.app" >&2; exit 1; }
[ -L "$MNT/Applications" ] || { echo "DMG is missing the Applications shortcut" >&2; exit 1; }
codesign --verify --deep --strict "$MNT/RAVE LIVE.app" || { echo "App inside the DMG fails codesign verification" >&2; exit 1; }

echo "built $OUT ($(du -h "$OUT" | cut -f1))"
