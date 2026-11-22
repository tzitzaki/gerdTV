#!/usr/bin/env bash
# Release notes for <tag>: the titles of the PRs merged since the previous tag (GitHub merge commits carry the PR
# title as the first body line), then the install hints. Usage: scripts/release-notes.sh <tag>
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
git log --first-parent --merges --format='%s%x1f%b%x1e' "$range" | while IFS=$'\x1f' read -r -d $'\x1e' subject body; do
  pr="$(sed -nE 's/^Merge pull request #([0-9]+).*/\1/p' <<<"$subject")"
  title="$(sed '/^[[:space:]]*$/d' <<<"$body" | head -1)"
  [[ -n "$pr" ]] && echo "- ${title:-$subject} (#$pr)"
done
[[ -n "$prev" ]] || echo "- First release."
cat <<'HINTS'

## Install
- macOS: unzip, move gerdTV.app to Applications; first open via System Settings > Privacy & Security > Open Anyway.
- Android / Android TV: install the APK (allow unknown sources once); later updates come through the app.
- iPhone/iPad: re-sign the unsigned IPA with your re-signing service; the app notifies about updates.
- Linux: unpack the tarball and run gerdTV/gerdtv.
- Details and checks: https://github.com/tzitzaki/gerdTV/blob/main/docs/INSTALL.md
HINTS
