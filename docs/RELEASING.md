# Releasing RAVE LIVE

Releases are built and published by GitHub Actions, never from a laptop: `.github/workflows/release.yml` runs only when
someone starts it by hand. It reads `VERSION`, refuses to run if that tag already exists, runs `swift test`, builds
Syphon, projectM and the Now Playing reader from pinned sources, fetches the bundled MilkDrop presets, builds the
universal app, refuses to ship without the engines or with fewer than 100 presets, then publishes the tag `v<VERSION>`
with `RAVE-LIVE.dmg` and `RAVE-LIVE.zip`. The release notes are `.github/release-notes.md` followed by the
`## [<VERSION>]` section of `CHANGELOG.md`.

## The sequence used for v0.5.1

This is the exact sequence that published v0.5.1 (2026-10-29, workflow run 40737895130 on `c399ebe`). Repeat it for the
next version with the PR number, head SHA and tag changed. Publishing is the maintainer's call; nothing here runs on
its own.

0. The release PR bumps `VERSION`, moves `## [Unreleased]` into `## [<version>]` in `CHANGELOG.md` (add ` - <date>` if
   the publish day is known; the notes don't show it, the workflow only matches the `## [<version>]` start), and updates
   the README (version under the download button, status line, "New in" section). It goes through the normal gate:
   `swift test` on the exact head SHA and CI green.
1. Merge it pinned to the head that was tested, then start the release from `main`:

   ```bash
   gh pr view <N> -R jedbrnth-eng/rave-live --json headRefOid,state,mergeable
   gh pr merge <N> -R jedbrnth-eng/rave-live --squash --match-head-commit <full 40-char head SHA>
   gh pr view <N> -R jedbrnth-eng/rave-live --json state,mergeCommit
   gh workflow run release.yml -R jedbrnth-eng/rave-live --ref main
   sleep 8
   gh run list -R jedbrnth-eng/rave-live --workflow release.yml -L 1
   ```

   Check that the run's `headSha` is the merge commit you just made.
2. Wait for the run. `gh run watch` can return while the run is still `in_progress`, so poll the status instead
   (about 6 minutes):

   ```bash
   RUN=<run id from step 1>
   for i in $(seq 1 80); do s=$(gh run view $RUN -R jedbrnth-eng/rave-live --json status -q .status); [ "$s" = completed ] && break; sleep 30; done
   gh run view $RUN -R jedbrnth-eng/rave-live --json conclusion,status
   gh release view -R jedbrnth-eng/rave-live --json tagName,assets,isDraft,url -q '{tag:.tagName,draft:.isDraft,url:.url,assets:[.assets[]|{name,size}]}'
   ```

3. Check what actually shipped, from the published zip:

   ```bash
   mkdir rl-rel && cd rl-rel
   gh release download v<version> -R jedbrnth-eng/rave-live -p RAVE-LIVE.zip
   ditto -x -k RAVE-LIVE.zip .
   A="$(ls -d *.app)"; echo "$A"
   /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$A/Contents/Info.plist"   # the new version
   ls "$A/Contents/Resources/MilkDrop" | wc -l                                                # 149 presets
   lipo -archs "$A/Contents/MacOS/"*                                                          # x86_64 arm64
   ```

   For v0.5.1 the DMG was 7,563,835 bytes.

## Before you start the workflow

- Preview the notes: the same `awk` the workflow uses, run locally, must match the draft (for 0.6.0,
  `RELEASE_NOTES_0.6.0.md` without its leading comment):

  ```bash
  v="$(tr -d '[:space:]' < VERSION)"
  { cat .github/release-notes.md; echo; awk -v h="## [$v]" 'index($0, h) == 1 {on = 1; print "## Changes in this version"; next} on && /^## \[/ {exit} on' CHANGELOG.md; } > /tmp/notes.md
  diff <(tail -n +7 "RELEASE_NOTES_$v.md") /tmp/notes.md && echo "notes match"
  ```

- `gh release list -R jedbrnth-eng/rave-live -L 3` must not list `v<version>` yet (the workflow stops if it does).
- The README's download button points at `releases/latest`, so between merging the release PR and the workflow
  finishing (about 6 minutes) the README describes a version the button doesn't serve yet. Merge and start the
  workflow in one go.
