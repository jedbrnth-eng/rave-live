#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Checks a built RAVE LIVE.app: universal binary (arm64 + x86_64), both slices built for macOS 12.0,
# Info.plist minimum 12.0, and both icon forms (Assets.car is optional; AppIcon.icns is what macOS 12-25 read).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/RAVE LIVE.app}"
EXE="$APP/Contents/MacOS/RaveLive"
test -x "$EXE"
plutil -lint "$APP/Contents/Info.plist"
ARCHS="$(lipo -archs "$EXE")"
echo "archs: $ARCHS"
for a in arm64 x86_64; do
  case " $ARCHS " in *" $a "*) ;; *) echo "::error::$a slice missing"; exit 1 ;; esac
  MINOS="$(otool -arch "$a" -l "$EXE" | awk '/LC_BUILD_VERSION/ {f = 1} f && $1 == "minos" {print $2; exit}')"
  echo "$a minos $MINOS"
  [ "$MINOS" = "12.0" ] || { echo "::error::$a slice minos is $MINOS, expected 12.0"; exit 1; }
done
MIN="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
[ "$MIN" = "12.0" ] || { echo "::error::LSMinimumSystemVersion is $MIN"; exit 1; }
test -f "$APP/Contents/Resources/AppIcon.icns"
[ "$(plutil -extract CFBundleIconFile raw "$APP/Contents/Info.plist")" = "AppIcon" ]
codesign --verify --deep --strict "$APP"
echo "app OK: universal, macOS 12.0+, icon present, signature valid"
