#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Optional: builds ungive/mediaremote-adapter (BSD-3-Clause, https://github.com/ungive/mediaremote-adapter) from a
# pinned tag into vendor/mediaremote-adapter (gitignored): MediaRemoteAdapter.framework (universal, macOS 12.0) and
# the mediaremote-adapter.pl script. make_app.sh bundles them when present. RAVE LIVE runs the script with
# /usr/bin/perl to read macOS Now Playing (lyrics + player card); without it the app builds and runs as before
# and Settings explains what is missing. Needs cmake (brew install cmake) and Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="https://github.com/ungive/mediaremote-adapter.git"
TAG="v0.7.7"
COMMIT="e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6"   # tag v0.7.7
SRC="vendor/mediaremote-adapter-src"
OUT="vendor/mediaremote-adapter"

command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)"; exit 1; }
mkdir -p vendor
if [ ! -d "$SRC/.git" ]; then git clone --quiet "$REPO" "$SRC"; fi
git -C "$SRC" fetch --quiet --tags origin 2>/dev/null || true
git -C "$SRC" checkout --quiet --detach "$COMMIT"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "mediaremote-adapter checkout is not at $TAG ($COMMIT)"; exit 1; }
git -C "$SRC" submodule update --init --recursive --quiet || { echo "mediaremote-adapter: submodule update failed (network?)"; exit 1; }

rm -rf vendor/mediaremote-adapter-build "$OUT"
cmake -S "$SRC" -B vendor/mediaremote-adapter-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 > vendor/mediaremote-adapter-build.log 2>&1 \
  && cmake --build vendor/mediaremote-adapter-build --config Release >> vendor/mediaremote-adapter-build.log 2>&1 \
  || { tail -40 vendor/mediaremote-adapter-build.log; echo "mediaremote-adapter build failed (full log: vendor/mediaremote-adapter-build.log)"; exit 1; }
mkdir -p "$OUT"
cp -R vendor/mediaremote-adapter-build/MediaRemoteAdapter.framework "$OUT/"
cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/"
cp "$SRC/LICENSE" "$OUT/LICENSE.txt"
echo "$TAG $COMMIT" > "$OUT/VERSION.txt"
lipo -info "$OUT/MediaRemoteAdapter.framework/MediaRemoteAdapter"
echo "built $OUT ($TAG)"
