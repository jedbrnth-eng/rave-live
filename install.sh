#!/bin/bash
# RAVE LIVE installer. Downloads the latest release, puts RAVE LIVE.app in /Applications and opens it.
# Source: https://github.com/jedbrnth-eng/rave-live
# Overrides (mainly for testing): RAVE_ZIP_URL=<url or file:// path>, RAVE_INSTALL_DIR=<folder>, RAVE_NO_OPEN=1
set -euo pipefail

REPO="jedbrnth-eng/rave-live"
URL="${RAVE_ZIP_URL:-https://github.com/$REPO/releases/latest/download/RAVE-LIVE.zip}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "RAVE LIVE is a Mac app. This installer only runs on macOS."
[ "$(uname -m)" = "arm64" ] || die "RAVE LIVE needs an Apple Silicon Mac (M1 or newer)."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || die "RAVE LIVE needs macOS 14 (Sonoma) or newer. You have $(sw_vers -productVersion)."

DEST="${RAVE_INSTALL_DIR:-/Applications}"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading RAVE LIVE..."
curl -fL --progress-bar -o "$TMP/RAVE-LIVE.zip" "$URL" || die "Download failed. Check your internet connection, or see the README to build from source."

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
echo "RAVE LIVE is in $DEST. Allow 'Screen & System Audio Recording' when macOS asks; nothing is recorded."
echo "Please read the photosensitivity warning in the README before using strobes."
echo "To remove it later: rm -rf \"$DEST/RAVE LIVE.app\""
