# gerdTV task runner. `just` lists the recipes. Gates and their order: CLAUDE.md ("Dev loop") and docs/SETUP.md.
# Heavy jobs (Android/Gradle builds, integration tests) take ~/.gerdTV-heavy.lock so only one runs at a time on a
# shared dev machine; CI runners have the lock to themselves.

set shell := ["bash", "-euo", "pipefail", "-c"]

heavy := "flock " + env_var('HOME') + "/.gerdTV-heavy.lock"

default:
    @just --list

# Print every toolchain version and flag what's missing (docs/SETUP.md).
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    missing=0
    check() { # name, command printing a version
      local out; if out="$(eval "$2" 2>/dev/null | head -1)" && [[ -n "$out" ]]; then printf '  ok   %-12s %s\n' "$1" "$out"
      else printf '  MISSING %-9s (%s)\n' "$1" "$2"; missing=1; fi
    }
    check rustc "rustc --version"
    check cargo "cargo --version"
    check flutter "flutter --version --suppress-analytics | head -1"
    check dart "dart --version 2>&1"
    check frb-codegen "flutter_rust_bridge_codegen --version"
    check cargo-ndk "cargo ndk --version"
    check java "java -version 2>&1"
    check android-sdk "ls -d \"${ANDROID_HOME:-$HOME/Android/Sdk}\"/platforms/* | xargs -n1 basename | tr '\n' ' '"
    check android-ndk "ls \"${ANDROID_HOME:-$HOME/Android/Sdk}\"/ndk | tr '\n' ' '"
    check libmpv "pkg-config --modversion mpv"
    check xvfb-run "command -v xvfb-run"
    check just "just --version"
    check gh "gh --version"
    check jq "jq --version"
    [[ "$(flutter --version --machine 2>/dev/null | jq -r .frameworkVersion)" == "$(cat app/FLUTTER_VERSION)" ]] \
      || { echo "  WARN  flutter is not the pinned $(cat app/FLUTTER_VERSION) (app/FLUTTER_VERSION)"; }
    exit $missing

# Regenerate the flutter_rust_bridge bindings after changing crates/gerdtv-api (output: app/lib/src/rust).
codegen:
    cd app && flutter_rust_bridge_codegen generate

# Format Rust and Dart in place.
fmt:
    cargo fmt --all
    cd app && dart format lib test integration_test

# Rust + Flutter unit and widget tests.
test: test-rust test-flutter

test-rust:
    cargo test --workspace --quiet

test-flutter: l10n
    cd app && flutter test

# Generate the localisation code (app/lib/l10n/gen, not committed). `flutter test` and `analyze` don't do it on a
# fresh clone; builds do.
l10n:
    cd app && flutter gen-l10n

# The repository rule tests (doc paths, HANDOVER/DEVICE_CHECKS limits, workflow rules, ARB files, names).
test-docs:
    cargo test -p gerdtv-testkit --test repo_rules --quiet

# The suites the changes since <base> can affect (the pre-push hook runs this).
test-affected base="origin/main":
    scripts/test-affected.sh {{base}}

# Integration tests on the Linux desktop build under Xvfb, with the testkit's fault server running alongside.
test-integration:
    {{heavy}} scripts/with-fault-server.sh bash -c 'cd app && xvfb-run -a flutter test integration_test -d linux --dart-define=GERDTV_FAULT_SERVER="$GERDTV_FAULT_SERVER"'

# Fails on a private detail in the changes since <base> or in the given files (e.g. a PR body draft).
denylist base="origin/main" *files="":
    scripts/check-denylist.sh {{base}} {{files}}

# Everything that has to be green before a PR is marked ready. Prints the lines for the PR body.
# Usage: just ready [<pr-body-draft.md>]
ready body="":
    #!/usr/bin/env bash
    set -euo pipefail
    lines=()
    step() { # label, command
      local t0=$SECONDS; echo "== $1"; eval "$2"; lines+=("- $1: green ($((SECONDS - t0)) s)")
    }
    step "denylist" "scripts/check-denylist.sh origin/main {{body}}"
    step "cargo fmt --check" "cargo fmt --all --check"
    step "clippy -D warnings" "cargo clippy --workspace --all-targets --quiet -- -D warnings"
    step "flutter analyze" "just l10n && (cd app && flutter analyze)"
    step "just test" "just test"
    step "licences" "just licences"
    step "integration tests (Linux, Xvfb)" "just test-integration"
    step "Linux release build" "just build-linux"
    echo; echo "PR body lines:"; printf '%s\n' "${lines[@]}"

# What the `linux` CI job runs (.github/workflows/ci.yml).
ci-linux:
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --quiet -- -D warnings
    just test
    just l10n
    cd app && flutter analyze
    just licences
    just test-integration
    just build-linux

build-linux:
    cd app && {{heavy}} flutter build linux --release

# Debug APK only; release APKs come from release.yml. Gradle gets 2 GB and no daemon on a shared machine.
build-android:
    cd app && GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.jvmargs=-Xmx2g" {{heavy}} flutter build apk --debug --target-platform android-arm64

# Download a release and check every asset's SHA-256 and the signed manifest (docs/RELEASING.md).
verify-release tag:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
    gh release download "{{tag}}" -R tzitzaki/gerdTV -D "$dir"
    cargo run -q -p gerdtv-release -- check keys/update-public-key.hex "$dir"

# Check that every bundled dependency's licence is GPL-3.0 compatible (scripts/licences.sh).
licences:
    scripts/licences.sh

# [MAC] sessions only: build and run the integration tests on a Mac.
mac-check:
    cd app && flutter build macos --debug
    scripts/with-fault-server.sh bash -c 'cd app && flutter test integration_test -d macos --dart-define=GERDTV_FAULT_SERVER="$GERDTV_FAULT_SERVER"'
