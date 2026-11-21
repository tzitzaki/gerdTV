#!/usr/bin/env bash
# Runs the test suites this branch's changes can affect (pre-push hook; `just test-affected`). Coarse on purpose:
#   crates/, Cargo.*, rust-toolchain.toml → all Rust tests;  app/ or crates/gerdtv-api → flutter analyze + test;
#   docs, *.md, .github/, justfile → the repo rule tests (doc paths, HANDOVER limits, workflow rules, ARB files).
# CI and `just ready` run everything. Debug: prints which suites it picked and why.
set -euo pipefail
base="${1:-origin/main}"
changed="$( (git diff --name-only "$base"; git ls-files --others --exclude-standard) | sort -u)"
rust=0 flutter=0 rules=0
while IFS= read -r f; do
  case "$f" in
    "") ;;
    crates/gerdtv-api/*) rust=1 flutter=1 ;;
    crates/*|Cargo.*|rust-toolchain.toml|keys/*) rust=1 ;;
    app/*) flutter=1; [[ "$f" == app/lib/l10n/* || "$f" == app/*/Info.plist || "$f" == *AndroidManifest.xml ]] && rules=1 ;;
    *) rules=1 ;;
  esac
done <<<"$changed"
echo "test-affected: rust=$rust flutter=$flutter rules=$rules (changed since $base)"
if [[ $rust == 1 ]]; then cargo test --workspace --quiet; elif [[ $rules == 1 ]]; then just test-docs; fi
if [[ $flutter == 1 ]]; then (just l10n && cd app && flutter analyze && flutter test); fi
