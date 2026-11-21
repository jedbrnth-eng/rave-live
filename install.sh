#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# RAVE LIVE installer. Downloads the latest release, puts RAVE LIVE.app in /Applications and opens it.
# Source: https://github.com/jedbrnth-eng/rave-live
# Overrides (mainly for testing): RAVE_ZIP_URL=<url or file:// path>, RAVE_INSTALL_DIR=<folder>, RAVE_NO_OPEN=1
set -euo pipefail

REPO="jedbrnth-eng/rave-live"
URL="https://github.com/$REPO/releases/latest/download/RAVE-LIVE.zip"
# HTTPS only, also across redirects (GitHub sends release downloads to its CDN).
CURL=(curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2)
# The testing override may point at a local server or a file.
if [ -n "${RAVE_ZIP_URL:-}" ]; then URL="$RAVE_ZIP_URL"; CURL=(curl -fL); fi
SUM_URL="$URL.sha256"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "RAVE LIVE is a Mac app. This installer only runs on macOS."
# One universal app: Apple silicon and Intel, macOS 12 or newer.
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 12 ] || die "RAVE LIVE needs macOS 12 (Monterey) or newer. You have $(sw_vers -productVersion)."

DEST="${RAVE_INSTALL_DIR:-/Applications}"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading RAVE LIVE..."
"${CURL[@]}" --progress-bar -o "$TMP/RAVE-LIVE.zip" "$URL" || die "Download failed. Check your internet connection, or see the README to build from source."

# Releases from 0.6.2 on publish RAVE-LIVE.zip.sha256 next to the zip. If it's there, the download must match it.
# Only a clean "404 not found" (a release older than 0.6.2) skips the check; any other failure stops the install.
SUM_HTTP="$("${CURL[@]}" -s -o "$TMP/RAVE-LIVE.zip.sha256" -w '%{http_code}' "$SUM_URL" 2>/dev/null)" || true
# A file:// download has no HTTP status: the checksum file is either there or it isn't.
case "$SUM_URL" in file://*) if [ -s "$TMP/RAVE-LIVE.zip.sha256" ]; then SUM_HTTP=200; else SUM_HTTP=404; fi ;; esac
if [ "$SUM_HTTP" = "200" ]; then
  WANT="$(awk 'NR==1 {print $1}' "$TMP/RAVE-LIVE.zip.sha256")"
  GOT="$(shasum -a 256 "$TMP/RAVE-LIVE.zip" | awk '{print $1}')"
  [[ "$WANT" =~ ^[0-9a-f]{64}$ ]] || die "The checksum file looks wrong. Nothing was installed. Please open an issue."
  [ "$WANT" = "$GOT" ] || die "Checksum mismatch: the download is damaged or was changed. Nothing was installed."
  say "Checksum OK ($GOT)"
elif [ "$SUM_HTTP" = "404" ]; then
  say "No checksum published for this release (older than 0.6.2); continuing without it."
else
  die "Couldn't download the checksum (HTTP ${SUM_HTTP:-none}). Nothing was installed; please try again."
fi

say "Installing to $DEST..."
ditto -x -k "$TMP/RAVE-LIVE.zip" "$TMP/out"
[ -d "$TMP/out/RAVE LIVE.app" ] || die "The download didn't contain RAVE LIVE.app. Please open an issue."

if pgrep -x RaveLive >/dev/null 2>&1; then
  osascript -e 'tell application "RAVE LIVE" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
rm -rf "$DEST/RAVE LIVE.app"
ditto "$TMP/out/RAVE LIVE.app" "$DEST/RAVE LIVE.app"
xattr -dr com.apple.quarantine "$DEST/RAVE LIVE.app" 2>/dev/null || true

if [ -z "${RAVE_NO_OPEN:-}" ]; then
  say "Done. Opening RAVE LIVE..."
  open "$DEST/RAVE LIVE.app"
else
  say "Done."
fi
echo
if [ "$MAJOR" -ge 13 ]; then
  echo "RAVE LIVE is in $DEST. Allow 'Screen & System Audio Recording' when macOS asks; nothing is recorded."
else
  echo "RAVE LIVE is in $DEST. On macOS 12 it listens to an input device: pick one in the Audio menu."
  echo "To visualize system audio, install the free BlackHole driver: https://github.com/jedbrnth-eng/rave-live/blob/main/docs/COMPATIBILITY.md"
fi
echo "Please read the photosensitivity warning in the README before using strobes."
echo "To remove it later: rm -rf \"$DEST/RAVE LIVE.app\""
