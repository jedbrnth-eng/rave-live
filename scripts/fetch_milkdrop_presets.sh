#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Fetches the bundled MilkDrop presets listed in Resources/MilkDrop/bundled.txt from the projectM
# "cream of the crop" pack at the pinned commit (the pack is a ~32 MB zip; only the listed files are kept), checks
# every file's SHA-256 and writes them to vendor/milkdrop-bundled/ in the pack's own layout, with the pack's
# LICENSE.md and an AUTHORS.txt built from the file names. make_app.sh copies that folder into
# "RAVE LIVE.app/Contents/Resources/MilkDrop". The preset files themselves are not committed.
set -euo pipefail
cd "$(dirname "$0")/.."
LIST=Resources/MilkDrop/bundled.txt
COMMIT=$(sed -n 's/^# commit \([0-9a-f]\{40\}\).*/\1/p' "$LIST" | head -1)
[ -n "$COMMIT" ] || { echo "fetch_milkdrop_presets: no '# commit <sha>' line in $LIST"; exit 1; }
ROOT="$PWD/vendor"
ZIP="$ROOT/presets-cream-of-the-crop-$COMMIT.zip"
OUT="$ROOT/milkdrop-bundled"
TOP="presets-cream-of-the-crop-master"          # the folder name of the pack's own download, so keys (favourites) match
mkdir -p "$ROOT"
[ -f "$ZIP" ] || curl -fsSL --retry 3 -o "$ZIP.part" "https://codeload.github.com/projectM-visualizer/presets-cream-of-the-crop/zip/$COMMIT"
[ -f "$ZIP.part" ] && mv "$ZIP.part" "$ZIP"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
SRC="$TMP/presets-cream-of-the-crop-$COMMIT"
[ -d "$SRC" ] || { echo "fetch_milkdrop_presets: unexpected zip layout"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/$TOP"
n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  sum="${line%%  *}"; rel="${line#*  }"
  [ -f "$SRC/$rel" ] || { echo "fetch_milkdrop_presets: missing in pack: $rel"; exit 1; }
  got=$(shasum -a 256 "$SRC/$rel" | cut -d' ' -f1)
  [ "$got" = "$sum" ] || { echo "fetch_milkdrop_presets: checksum mismatch: $rel"; exit 1; }
  mkdir -p "$OUT/$TOP/$(dirname "$rel")"
  cp "$SRC/$rel" "$OUT/$TOP/$rel"
  n=$((n + 1))
done < "$LIST"
cp "$SRC/LICENSE.md" "$OUT/$TOP/LICENSE.md"
{
  echo "MilkDrop presets bundled with RAVE LIVE, from the projectM \"cream of the crop\" pack"
  echo "(https://github.com/projectM-visualizer/presets-cream-of-the-crop, commit $COMMIT)."
  echo "Authors as named in the preset file names (\"Author - Title.milk\"), with the number of presets each:"
  echo
  grep -v '^#' "$LIST" | sed -n 's/^[0-9a-f]*  //p' | sed 's|.*/||; s|\.milk$||' | awk -F' - ' 'NF > 1 {print $1} NF == 1 {print "(unnamed)"}' | sort | uniq -c | sort -rn | sed 's/^ *\([0-9]*\) \(.*\)/\2 (\1)/'
  echo
  echo "See LICENSE.md: the presets were released freely and are treated as public domain; authors can ask for removal."
} > "$OUT/$TOP/AUTHORS.txt"
echo "fetched $n bundled MilkDrop presets into $OUT"
