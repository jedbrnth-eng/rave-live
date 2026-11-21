#!/usr/bin/env bash
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Tests install.sh against a made-up release served from this machine (no internet, no real /Applications,
# nothing is opened). Cases: matching checksum installs, a changed download is refused, a broken checksum file
# is refused, a release with no checksum (older than 0.6.2) still installs, and a file:// download works.
#   scripts/test_install.sh
set -u
cd "$(dirname "$0")/.."
fail=0
check() { if [ "$2" = "0" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }

work="$(mktemp -d)"
cleanup() { [ -n "${srv:-}" ] && kill "$srv" 2>/dev/null && wait "$srv" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

# install.sh quits a running RAVE LIVE before replacing it. A test must never do that to the real app.
mkdir -p "$work/bin"; printf '#!/bin/sh\nexit 1\n' > "$work/bin/pgrep"; chmod +x "$work/bin/pgrep"
export PATH="$work/bin:$PATH" RAVE_NO_OPEN=1

mkdir -p "$work/src/RAVE LIVE.app/Contents/MacOS" "$work/srv"
echo "not a real app" > "$work/src/RAVE LIVE.app/Contents/MacOS/RaveLive"
ditto -c -k --keepParent "$work/src/RAVE LIVE.app" "$work/srv/RAVE-LIVE.zip"
(cd "$work/srv" && shasum -a 256 RAVE-LIVE.zip > RAVE-LIVE.zip.sha256)
port=$((20000 + RANDOM % 20000))
(cd "$work/srv" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & srv=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fs -o /dev/null "http://127.0.0.1:$port/RAVE-LIVE.zip" && break; sleep 0.5; done
export RAVE_ZIP_URL="http://127.0.0.1:$port/RAVE-LIVE.zip"

run() { RAVE_INSTALL_DIR="$work/apps$1" bash install.sh >"$work/out$1.log" 2>&1; }
installed() { [ -f "$work/apps$1/RAVE LIVE.app/Contents/MacOS/RaveLive" ]; }

echo "matching checksum"
mkdir -p "$work/apps1"; run 1; check "installer exits 0" "$?"
installed 1; check "app installed" "$?"
grep -q "Checksum OK" "$work/out1.log"; check "says the checksum matched" "$?"

echo "changed download is refused"
printf 'x' >> "$work/srv/RAVE-LIVE.zip"
mkdir -p "$work/apps2"; run 2; [ $? -ne 0 ]; check "installer exits non-zero" "$?"
grep -qi "checksum" "$work/out2.log"; check "says why (checksum)" "$?"
! installed 2; check "nothing installed" "$?"

echo "broken checksum file is refused"
echo "<html>not a checksum</html>" > "$work/srv/RAVE-LIVE.zip.sha256"
mkdir -p "$work/apps3"; run 3; [ $? -ne 0 ]; check "installer exits non-zero" "$?"
! installed 3; check "nothing installed" "$?"

echo "release without a checksum (older than 0.6.2) still installs"
ditto -c -k --keepParent "$work/src/RAVE LIVE.app" "$work/srv/RAVE-LIVE.zip"
rm "$work/srv/RAVE-LIVE.zip.sha256"
mkdir -p "$work/apps4"; run 4; check "installer exits 0" "$?"
installed 4; check "app installed" "$?"
grep -qi "no checksum" "$work/out4.log"; check "says there was no checksum" "$?"

echo "file:// download"
(cd "$work/srv" && shasum -a 256 RAVE-LIVE.zip > RAVE-LIVE.zip.sha256)
export RAVE_ZIP_URL="file://$work/srv/RAVE-LIVE.zip"
mkdir -p "$work/apps5"; run 5; check "installer exits 0" "$?"
grep -q "Checksum OK" "$work/out5.log"; check "says the checksum matched" "$?"
printf 'x' >> "$work/srv/RAVE-LIVE.zip"
mkdir -p "$work/apps6"; run 6; [ $? -ne 0 ]; check "changed file is refused" "$?"
! installed 6; check "nothing installed" "$?"

[ "$fail" -eq 0 ] && echo "INSTALL TESTS: PASS" || echo "INSTALL TESTS: FAIL"
exit "$fail"
