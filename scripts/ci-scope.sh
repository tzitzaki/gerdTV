#!/usr/bin/env bash
# CI: decides whether a job has real work. `main` requires the linux/macos/android checks, so docs-only PRs still run
# every job; this makes those jobs end green in seconds. Writes code=true|false to $GITHUB_OUTPUT.
# Usage (in a job after a full-history checkout): scripts/ci-scope.sh <base-sha>; no base (manual run) → code=true.
set -euo pipefail
base="${1:-}"
code=true
if [[ -n "$base" ]]; then
  changed="$(git diff --name-only "$base"...HEAD)"
  echo "changed files:"; sed 's/^/  /' <<<"$changed"
  if [[ -n "$changed" ]] && ! grep -qv '\.md$' <<<"$changed"; then code=false; fi
fi
echo "code=$code" | tee -a "${GITHUB_OUTPUT:-/dev/null}"
