#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Optional: builds Syphon.framework (BSD-3-Clause, https://github.com/Syphon/Syphon-Framework) from a pinned
# source commit into vendor/ (gitignored), universal arm64 + x86_64, macOS 12.0 deployment target.
# make_app.sh embeds vendor/Syphon.framework when it exists; RAVE LIVE loads it at runtime, so the app
# builds and runs without it (Output > Syphon is then disabled). Needs Xcode (xcodebuild).
set -euo pipefail
cd "$(dirname "$0")/.."
SYPHON_REPO="https://github.com/Syphon/Syphon-Framework.git"
SYPHON_COMMIT="f4761677a45b8034a3c2069ec0f3d2553da81fba"   # main, 2026-09-21
SRC="vendor/syphon-src"
OUT="vendor/Syphon.framework"

mkdir -p vendor
if [ ! -d "$SRC/.git" ]; then git clone --quiet "$SYPHON_REPO" "$SRC"; fi
git -C "$SRC" fetch --quiet origin "$SYPHON_COMMIT" 2>/dev/null || true
git -C "$SRC" checkout --quiet --detach "$SYPHON_COMMIT"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$SYPHON_COMMIT" ] || { echo "Syphon checkout is not at $SYPHON_COMMIT"; exit 1; }

rm -rf vendor/syphon-build "$OUT"
xcodebuild -project "$SRC/Syphon.xcodeproj" -target Syphon -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/vendor/syphon-build" OBJROOT="$PWD/vendor/syphon-build/obj" \
  build > vendor/syphon-build.log 2>&1 || { tail -40 vendor/syphon-build.log; echo "Syphon build failed (full log: vendor/syphon-build.log)"; exit 1; }
cp -R vendor/syphon-build/Release/Syphon.framework "$OUT"
cp "$SRC/License.txt" "$OUT/Versions/A/Resources/License.txt"
lipo -info "$OUT/Syphon"
echo "built $OUT ($(otool -D "$OUT/Syphon" | tail -1))"
