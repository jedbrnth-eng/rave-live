#!/bin/sh
# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

# Fails if the repo leaks personal data. Run before any release; CI runs it too.
# Checks: absolute home paths, email addresses, @local commit authors, local library listings,
# .DS_Store in history, and build-machine paths baked into built binaries (when a build exists).
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0

# 1. absolute user paths in tracked files (this script and the release checklist may name the pattern)
hits=$(git grep -n -I -E '(/Users/[A-Za-z0-9._-]+/|~/(Music|Downloads|Movies)/)' -- . ':!scripts/check_public_ready.sh')
if [ -n "$hits" ]; then echo "FAIL: absolute /Users/... paths in tracked files:"; echo "$hits" | cut -c1-140 | head -10; fail=1; fi

# 2. machine-local commit identities
bad=$(git log --all --format='%ae' | grep -E '@local$' | sort -u)
if [ -n "$bad" ]; then echo "FAIL: commit author emails ending in @local: $bad"; fail=1; fi

# 3. Serato library listings / generated per-track bench output
lib=$(git ls-files | grep -E '^(bench/tracks.*\.json|bench/results/|bench_tracks\.json|bench_results_.*\.json|tools/gt_edm/)')
if [ -n "$lib" ]; then echo "FAIL: personal library data tracked:"; echo "$lib" | head -5; fail=1; fi

# 4. .DS_Store anywhere in history
ds=$(git log --all --name-only --pretty=format: | grep -c '\.DS_Store')
if [ "$ds" -gt 0 ]; then echo "FAIL: .DS_Store present in history ($ds entries)"; fail=1; fi

# 5. email addresses in tracked files (GitHub noreply addresses and the reserved example domains are fine)
em=$(git grep -n -I -E -o '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}' -- . ':!scripts/check_public_ready.sh' | grep -v -E '@(users\.noreply\.github\.com|example\.(com|org|net))$')
if [ -n "$em" ]; then echo "FAIL: email addresses in tracked files:"; echo "$em" | head -5; fail=1; fi

# 6. build-machine paths baked into built binaries (skipped if nothing is built)
for b in .build/release/RaveLiveApp .build/release/rave-probe; do
  if [ -f "$b" ] && strings -a "$b" | grep -q -E '/(Users|home)/[A-Za-z0-9._-]+/'; then
    echo "FAIL: $b embeds a home-directory path (check #filePath / #file usage)"; fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "OK: no personal data found"
exit "$fail"
