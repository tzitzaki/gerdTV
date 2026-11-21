#!/usr/bin/env bash
# Release notes for <tag>: the titles of the PRs merged since the previous tag (GitHub merge commits carry the PR
# title as the first body line), then the install hints. Usage: scripts/release-notes.sh <tag>
set -euo pipefail
tag="$1"
prev="$(git describe --tags --abbrev=0 --match 'v*' "$tag^" 2>/dev/null || true)"
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
