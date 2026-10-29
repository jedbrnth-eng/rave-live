#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Builds libprojectM (LGPL-2.1-or-later, https://github.com/projectM-visualizer/projectm) for the MILKDROP mode.
# Fetches the pinned release source into vendor/ (gitignored), applies scripts/projectm-patches/*.patch and
# builds a universal (arm64 + x86_64), macOS 12.0+ shared library:
#   vendor/projectm/lib/libprojectM-4.dylib   (install name @rpath/libprojectM-4.dylib)
#   vendor/projectm/include/projectM-4/*.h
# make_app.sh copies the dylib into "RAVE LIVE.app/Contents/Frameworks". The app loads it at runtime (dlopen), so
# RAVE LIVE builds and runs without it and anyone can swap in their own build (LGPL relinking).
# Needs cmake (brew install cmake); uses ninja when it is installed.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)"; exit 1; }
VER=4.1.8
SHA256=f72135e8b8e5fd807f908537255b41ac7ba4830309265e830cb756535487239e
URL="https://github.com/projectM-visualizer/projectm/releases/download/v$VER/libprojectM-$VER.tar.gz"
ROOT="$PWD/vendor"
SRC="$ROOT/libprojectM-$VER"
OUT="$ROOT/projectm"
mkdir -p "$ROOT"

TARBALL="$ROOT/libprojectM-$VER.tar.gz"
[ -f "$TARBALL" ] || curl -fL --retry 3 -o "$TARBALL" "$URL"
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

# Fresh, patched source tree every time (the patch is the only change to upstream).
rm -rf "$SRC"; tar xzf "$TARBALL" -C "$ROOT"
for p in scripts/projectm-patches/*.patch; do (cd "$SRC" && patch -p1 --forward < "$OLDPWD/$p"); done

# Ninja when installed, else CMake's default (Makefiles). ${GEN[@]+...}: macOS bash 3.2 treats an empty array as unset
# under `set -u`, so a plain "${GEN[@]}" failed with "GEN[@]: unbound variable" on Macs without ninja.
GEN=(); command -v ninja >/dev/null && GEN=(-G Ninja)
rm -rf "$ROOT/build-projectm" "$OUT"
cmake -S "$SRC" -B "$ROOT/build-projectm" ${GEN[@]+"${GEN[@]}"} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_INSTALL_PREFIX="$OUT" \
  -DCMAKE_INSTALL_NAME_DIR="@rpath" \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_PLAYLIST=OFF \
  -DENABLE_SYSTEM_GLM=OFF \
  -DENABLE_SYSTEM_PROJECTM_EVAL=OFF \
  -DENABLE_SDL_UI=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILD_DOCS=OFF \
  -DENABLE_DEBUG_POSTFIX=OFF
cmake --build "$ROOT/build-projectm" --parallel
cmake --install "$ROOT/build-projectm"

# One stable file name for the app to dlopen, whatever SONAME versioning upstream uses.
LIB="$(cd "$OUT/lib" && ls libprojectM-4.*dylib 2>/dev/null | head -1)"
[ -n "$LIB" ] || { echo "build_projectm: no libprojectM-4 dylib produced"; exit 1; }
cp -L "$OUT/lib/$LIB" "$OUT/lib/libprojectM-4.dylib.tmp"
find "$OUT/lib" -maxdepth 1 -name 'libprojectM-4*.dylib' -delete
mv "$OUT/lib/libprojectM-4.dylib.tmp" "$OUT/lib/libprojectM-4.dylib"
install_name_tool -id "@rpath/libprojectM-4.dylib" "$OUT/lib/libprojectM-4.dylib"
codesign --force --sign - "$OUT/lib/libprojectM-4.dylib" 2>/dev/null || true
lipo -info "$OUT/lib/libprojectM-4.dylib"
nm -gU "$OUT/lib/libprojectM-4.dylib" | grep -q projectm_opengl_render_frame_fbo || { echo "build_projectm: patch symbol missing"; exit 1; }
echo "built $OUT/lib/libprojectM-4.dylib"
