#!/usr/bin/env bash
# Runs the test suites this branch's changes can affect (pre-push hook; `just test-affected`). The areas come from
# scripts/ci-scope.sh, the same map CI uses: rust → all Rust tests (the repo rules included); flutter → flutter
# analyze + test; rules alone → the repo rule tests. The platform builds and integration tests are left to CI.
# CI and `just ready` run everything. Debug: prints which areas it picked and the changed files.
set -euo pipefail
base="${1:-origin/main}"
scope="$(scripts/ci-scope.sh --worktree "$base")"
on() { grep -qx "$1=true" <<<"$scope"; }
echo "test-affected: $(tr '\n' ' ' <<<"$scope")(changed since $base)"
if on rust; then cargo test --workspace --quiet; elif on rules; then just test-docs; fi
if on flutter; then (just l10n && cd app && flutter analyze && flutter test); fi
