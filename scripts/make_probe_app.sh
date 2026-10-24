#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Wraps rave-probe in a signed .app so macOS can grant it Screen & System Audio Recording.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/RaveLiveProbe.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/rave-probe "$APP/Contents/MacOS/rave-probe"
cat > "$APP/Contents/MacOS/launcher" <<'SH'
#!/bin/bash
# args come from RAVE_ARGS file so `open` can pass them
DIR="$(cd "$(dirname "$0")" && pwd)"
ARGS_FILE="$HOME/.cache/ravelive/args"; LOG="$HOME/.cache/ravelive/probe.log"
mkdir -p "$(dirname "$LOG")"
if [ -r "$ARGS_FILE" ]; then read -r -a ARGV < "$ARGS_FILE"; else ARGV=(live 15); fi   # plain word split, never eval
"$DIR/rave-probe" "${ARGV[@]}" > "$LOG" 2>&1
echo "EXIT $?" >> "$LOG"
SH
chmod +x "$APP/Contents/MacOS/launcher"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.jedbrnth-eng.ravelive.probe</string>
<key>CFBundleName</key><string>RaveLive Probe</string>
<key>CFBundleExecutable</key><string>launcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Fallback input: RAVE LIVE listens to your mic or audio interface when system audio is not available.</string>
<key>NSScreenCaptureUsageDescription</key><string>RAVE LIVE reads the audio your Mac is playing so the visuals react to the beat. It does not record your screen.</string>
</dict></plist>
PL
# Prefer an Apple Development identity; fall back to ad-hoc signing so anyone can build.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  codesign --force --deep --sign "Apple Development" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority=Apple Dev"
echo "built $APP"
