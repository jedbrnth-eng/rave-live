#!/bin/bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Builds build/RAVE LIVE.app: one universal binary (Apple silicon + Intel) for macOS 12.0+.
# Signed with a local Apple Development identity if present, else ad-hoc. Not notarized.
# RAVE_ARCHS="arm64" (or "x86_64") builds a single-arch app for quicker local iterations.
set -euo pipefail
cd "$(dirname "$0")/.."
MIN_MACOS=12.0
ARCH_FLAGS=()
for a in ${RAVE_ARCHS:-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}" --product RaveLiveApp
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/RaveLiveApp"
APP="build/RAVE LIVE.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/RaveLive"
# SwiftPM stamps the SDK version = deployment target (12.0), which would switch AppKit's linked-on-or-after
# behaviour on newer macOS back to macOS 12 rules. Stamp 14.0 so macOS 13+ behaves exactly as before.
vtool -set-build-version macos "$MIN_MACOS" 14.0 -replace -output "$APP/Contents/MacOS/RaveLive" "$APP/Contents/MacOS/RaveLive" 2>/dev/null
echo "binary: $(lipo -archs "$APP/Contents/MacOS/RaveLive")"
# MILKDROP engine (LGPL libprojectM, loaded at runtime): bundled when scripts/build_projectm.sh has been run.
if [ -f vendor/projectm/lib/libprojectM-4.dylib ]; then
  mkdir -p "$APP/Contents/Frameworks"; cp vendor/projectm/lib/libprojectM-4.dylib "$APP/Contents/Frameworks/"
else echo "note: no vendor/projectm build; MILKDROP mode will show its 'engine missing' card (run scripts/build_projectm.sh)"; fi
# Bundled MilkDrop presets (Resources/MilkDrop/bundled.txt, fetched at the pinned pack commit by scripts/fetch_milkdrop_presets.sh)
if [ -d vendor/milkdrop-bundled ]; then
  mkdir -p "$APP/Contents/Resources/MilkDrop" && cp -R vendor/milkdrop-bundled/ "$APP/Contents/Resources/MilkDrop/"
  echo "bundled MilkDrop presets: $(find "$APP/Contents/Resources/MilkDrop" -name '*.milk' | wc -l | tr -d ' ')"
else echo "note: no vendor/milkdrop-bundled; MILKDROP starts without presets (run scripts/fetch_milkdrop_presets.sh)"; fi
# App icon: Icon Composer bundle compiled by actool -> Assets.car (macOS 26+ native squircle) + AppIcon.icns fallback.
mkdir -p "$APP/Contents/Resources"
RES="$(cd "$APP/Contents/Resources" && pwd)"
xcrun actool "$PWD/Resources/AppIcon/AppIcon.icon" --compile "$RES" --app-icon AppIcon \
  --platform macosx --minimum-deployment-target "$MIN_MACOS" --target-device mac \
  --output-partial-info-plist "$RES/../icon-partial.plist" >/dev/null 2>&1 || true
if [ ! -f "$RES/Assets.car" ] || [ ! -f "$RES/AppIcon.icns" ]; then
  # Icon Composer bundles need Xcode 26's actool. Older Xcode: plain .icns from the 1024 px master.
  # macOS 12-25 read CFBundleIconFile (the .icns), so it must exist even when Assets.car was built.
  [ -f "$RES/Assets.car" ] || echo "note: actool could not compile AppIcon.icon (needs Xcode 26); using a plain AppIcon.icns"
  SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon/master_1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon/master_1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$RES/AppIcon.icns"
fi
[ -f "$RES/AppIcon.icns" ] || { echo "no AppIcon.icns produced (needed on macOS 12-25)"; exit 1; }
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
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>RAVE LIVE listens to the input you pick in the Audio menu (mic, audio interface, DJ mixer, loopback driver). Audio is analysed on this Mac only and never recorded.</string>
<key>NSCameraUsageDescription</key><string>AURORA mode lets you paint the light show with your hands and body. Video is analysed on this Mac only and never recorded or sent anywhere.</string>
<key>NSScreenCaptureUsageDescription</key><string>RAVE LIVE reads the audio your Mac is playing so the visuals react to the beat. It does not record your screen.</string>
</dict></plist>
PL
# Shader Lab examples (copied to the user's Shaders folder on first launch) + .ravelook document type
mkdir -p "$APP/Contents/Resources/Shaders" && cp community/shaders/*.metal community/shaders/README.txt "$APP/Contents/Resources/Shaders/"
/usr/libexec/PlistBuddy -c "Merge Resources/DocumentTypes.plist" "$APP/Contents/Info.plist" >/dev/null
VERSION="$(tr -d '[:space:]' < VERSION)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$APP/Contents/Info.plist"
# Optional Syphon output (scripts/build_syphon.sh builds vendor/Syphon.framework); loaded at runtime when present.
if [ -d vendor/Syphon.framework ]; then
  mkdir -p "$APP/Contents/Frameworks" && cp -R vendor/Syphon.framework "$APP/Contents/Frameworks/"
fi
# Sign with a local Apple Development identity when there is one (keeps macOS permission grants
# stable across rebuilds); otherwise ad-hoc, so anyone can build. Override with RAVE_SIGN_IDENTITY.
IDENTITY="${RAVE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  IDENTITY="Apple Development"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "built $APP"
