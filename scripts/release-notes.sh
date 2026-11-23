#!/usr/bin/env bash
# Release notes for <tag>: the titles of the PRs merged since the previous tag (GitHub merge commits carry the PR
# title as the first body line), each with its commit subjects below when it has more than one (a session is one PR
# with a commit per feature; the wrap-up's "Version …" commit and merges from main are left out), then the install
# hints. Usage: scripts/release-notes.sh <tag>
# "Previous" is the newest earlier v* tag with a published release (`gh release view`; the publish job has a token):
# a tag whose release run failed has none, and its PRs belong in these notes.
set -euo pipefail
tag="$1"
prev=""
for t in $(git tag --merged "$tag^" --list 'v*' --sort=-version:refname); do
  if gh release view "$t" >/dev/null 2>&1; then prev="$t"; break; fi
done
range="${prev:+$prev..}$tag"
echo "## Changes"
git log --first-parent --merges --format='%H%x1f%s%x1f%b%x1e' "$range" | while IFS=$'\x1f' read -r -d $'\x1e' merge subject body; do
  merge="${merge//$'\n'/}"   # git log puts a newline between records
  pr="$(sed -nE 's/^Merge pull request #([0-9]+).*/\1/p' <<<"$subject")"
  title="$(sed '/^[[:space:]]*$/d' <<<"$body" | head -1)"
  [[ -n "$pr" ]] || continue
  echo "- ${title:-$subject} (#$pr)"
  # The PR's own commits: reachable from its head (the merge's second parent), not from main before the merge.
  commits="$(git log --no-merges --reverse --format=%s "$merge^1..$merge^2" | grep -vE '^Version 0\.' || true)"
  if [[ "$(grep -c . <<<"$commits")" -gt 1 ]]; then sed 's/^/  - /' <<<"$commits"; fi
done
[[ -n "$prev" ]] || echo "- First release."
cat <<'HINTS'

## Install
- macOS: open the DMG, drag gerdTV to Applications; first open via System Settings > Privacy & Security > Open Anyway.
- Android / Android TV: install the APK (allow unknown sources once); later updates come through the app.
- iPhone/iPad: re-sign the unsigned IPA with your re-signing service; the app notifies about updates.
- Linux: unpack the tarball and run gerdTV/gerdtv.
- Details and checks: https://github.com/tzitzaki/gerdTV/blob/main/docs/INSTALL.md
HINTS
