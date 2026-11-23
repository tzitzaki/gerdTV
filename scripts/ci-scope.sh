#!/usr/bin/env bash
# Which areas a change touches: the one map for CI (.github/workflows/ci.yml skips the steps of untouched areas) and
# the pre-push hook (scripts/test-affected.sh). `main` requires the linux/macos/android checks, so every job still
# runs; a job without work ends green in seconds.
# Areas: rust (fmt, clippy, Rust tests, libmpv harnesses), flutter (analyze, Flutter tests), linux (Linux build +
# integration tests), macos (macOS build + integration tests, DMG, iOS compile), android (debug APK), rules (the repo
# rule tests; the Rust tests include them).
# Prints area=true|false lines, also into $GITHUB_OUTPUT. Unknown paths touch every area (nothing slips through).
# Usage: scripts/ci-scope.sh <base>              changes on base...HEAD (CI, after a full-history checkout)
#        scripts/ci-scope.sh --worktree <base>   changes from base to the working tree, untracked files included
# No base (a manual run, a push to main) or no changes: every area.
# Debug: it prints the changed files; rerun it locally with the PR's base SHA.
set -euo pipefail
worktree=0
[[ "${1:-}" == "--worktree" ]] && { worktree=1; shift; }
base="${1:-}"
areas=(rust flutter linux macos android rules)
declare -A on
for a in "${areas[@]}"; do on[$a]=false; done
all() { for a in "${areas[@]}"; do on[$a]=true; done; }
set_on() { for a in "$@"; do on[$a]=true; done; }

if [[ -z "$base" ]]; then
  all
else
  if [[ $worktree == 1 ]]; then range=("$base"); else range=("$base...HEAD"); fi
  changed="$( (git diff --name-only "${range[@]}"; if [[ $worktree == 1 ]]; then git ls-files --others --exclude-standard; fi) | sort -u)"
  echo "changed files:" >&2; sed 's/^/  /' <<<"$changed" >&2
  [[ -z "$changed" ]] && all
  # A wrap-up's version bump: every changed line in the file is gerdTV's own version 0.YYMMDD.<PR#> (a dependency's
  # version never has a six-digit minor), so the file counts like a doc.
  version_only() {
    ! git diff -U0 "${range[@]}" -- "$1" | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' \
      | grep -qvE '^[-+]version( = "|: )0\.[0-9]{6}\.[0-9]+'
  }
  while IFS= read -r f; do
    case "$f" in
      "") ;;
      Cargo.toml|Cargo.lock|app/pubspec.yaml)
        if version_only "$f"; then set_on rules; else all; fi ;;
      *.md) set_on rules ;;
      crates/*|rust-toolchain.toml|keys/*) all ;;
      scripts/build-libmpv*) set_on rust linux ;;
      app/linux/*) set_on flutter linux ;;
      app/macos/*|app/ios/*) set_on macos ;;
      app/android/*) set_on android ;;
      # The Rust side's build glue for every platform.
      app/rust_builder/*|app/flutter_rust_bridge.yaml) all ;;
      app/*) set_on flutter linux macos android ;;
      *) all ;;
    esac
    # Files the repo rules read (ARB keys, the app name on every platform).
    case "$f" in app/lib/l10n/*|app/*/Info.plist|*AndroidManifest.xml) set_on rules ;; esac
  done <<<"$changed"
fi
for a in "${areas[@]}"; do echo "$a=${on[$a]}"; done | tee -a "${GITHUB_OUTPUT:-/dev/null}"
