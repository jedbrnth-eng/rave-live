#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Builds build/RAVE LIVE.app. Signed with a local Apple Development identity if present, else ad-hoc. Not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product RaveLiveApp
APP="build/RAVE LIVE.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/RaveLiveApp "$APP/Contents/MacOS/RaveLive"
# App icon: Icon Composer bundle compiled by actool -> Assets.car (macOS 26+ native squircle) + AppIcon.icns fallback.
mkdir -p "$APP/Contents/Resources"
RES="$(cd "$APP/Contents/Resources" && pwd)"
xcrun actool "$PWD/Resources/AppIcon/AppIcon.icon" --compile "$RES" --app-icon AppIcon \
  --platform macosx --minimum-deployment-target 14.0 --target-device mac \
  --output-partial-info-plist "$RES/../icon-partial.plist" >/dev/null 2>&1 || true
if [ ! -f "$RES/Assets.car" ]; then
  # Icon Composer bundles need Xcode 26's actool. Older Xcode: plain .icns from the 1024 px master.
  echo "note: actool could not compile AppIcon.icon (needs Xcode 26); using a plain AppIcon.icns"
  SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon/master_1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon/master_1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$RES/AppIcon.icns"
fi
[ -f "$RES/Assets.car" ] || [ -f "$RES/AppIcon.icns" ] || { echo "no app icon produced"; exit 1; }
rm -f "$APP/Contents/icon-partial.plist"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.jedbrnth-eng.ravelive</string>
<key>CFBundleName</key><string>RAVE LIVE</string>
<key>CFBundleDisplayName</key><string>RAVE LIVE</string>
<key>CFBundleExecutable</key><string>RaveLive</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Fallback input: RAVE LIVE listens to your mic or audio interface (turntables, line-in) when system audio isn't available.</string>
<key>NSCameraUsageDescription</key><string>AURORA mode lets you paint the light show with your hands and body. Video is analysed on this Mac only and never recorded or sent anywhere.</string>
<key>NSScreenCaptureUsageDescription</key><string>RAVE LIVE reads the audio your Mac is playing so the visuals react to the beat. It does not record your screen.</string>
</dict></plist>
PL
VERSION="$(tr -d '[:space:]' < VERSION)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
# Sign with a local Apple Development identity when there is one (keeps macOS permission grants
# stable across rebuilds); otherwise ad-hoc, so anyone can build. Override with RAVE_SIGN_IDENTITY.
IDENTITY="${RAVE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  IDENTITY="Apple Development"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "built $APP"
