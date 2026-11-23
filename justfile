# gerdTV task runner. `just` lists the recipes. Gates and their order: CLAUDE.md ("Dev loop") and docs/SETUP.md.
# Heavy jobs (Android/Gradle builds, integration tests, benchmarks) take ~/.gerdTV-heavy.lock so only one runs at a time on a
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
    cargo fmt --all   # the generated Rust isn't rustfmt-clean, and `just ready` checks formatting

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

# Render the logo mockups (app/lib/screens/app_logo.dart) into the launcher icon files and app/build/logos/preview.png.
logos:
    cd app && flutter test tool/render_logos_test.dart

# Generate the localisation code (app/lib/l10n/gen, not committed). `flutter test` and `analyze` don't do it on a
# fresh clone; builds do.
l10n:
    cd app && flutter gen-l10n

# The repository rule tests (doc paths, HANDOVER/DEVICE_CHECKS limits, workflow rules, ARB files, names).
test-docs:
    cargo test -p gerdtv-testkit --test repo_rules --quiet

# The libmpv harness: real libmpv driven by the watchdog against the fault server, one fault per test, serially.
test-harness:
    cargo test -q -p gerdtv-testkit --test libmpv_watchdog -- --ignored --nocapture --test-threads 1 --skip soak

# The soak: GERDTV_SOAK_MINUTES (default 30) of playback with random faults; every fault must recover (nightly).
soak:
    cargo test -q -p gerdtv-testkit --release --test libmpv_watchdog soak -- --ignored --nocapture

# The suites the changes since <base> can affect (the pre-push hook runs this).
test-affected base="origin/main":
    scripts/test-affected.sh {{base}}

# The core's performance budgets. A regression of more than 20 % against the saved `main` baseline fails.
# The baseline lives outside the worktrees (CRITERION_HOME), so every worktree compares against the same one;
# `just bench-save` records it (the wrap-up does, on main). No baseline yet: this run becomes it.
# Lenient: a benchmark added since the baseline is measured, not compared (strict mode aborts on it).
criterion_home := env_var('HOME') + "/.cache/gerdtv-criterion"

bench:
    #!/usr/bin/env bash
    set -euo pipefail
    export CRITERION_HOME="{{criterion_home}}"
    if [[ ! -d "$CRITERION_HOME/budgets" ]]; then just bench-save; exit 0; fi
    # Under the heavy lock: a build or test run beside it skews the timings (seen: false regressions of +25–39 %).
    out="$({{heavy}} cargo bench -q -p gerdtv-core --bench budgets -- --baseline-lenient main --noise-threshold 0.20 2>&1)" ||
        { echo "$out"; exit 1; }
    grep -E 'time:|change:|regressed|improved' <<<"$out" || true
    ! grep -q "Performance has regressed" <<<"$out"

bench-save:
    CRITERION_HOME="{{criterion_home}}" {{heavy}} cargo bench -q -p gerdtv-core --bench budgets -- --save-baseline main

# The full-scale guide import budget (2,000 channels × 7 days in < 60 s); slow, also in the nightly.
test-epg-budget:
    cargo test -q -p gerdtv-core --release --test epg_budget -- --ignored --nocapture

# Opt-in checks against the real account in the GERDTV_* environment (counts and timings only; docs/SETUP.md).
test-live:
    cargo test -q -p gerdtv-core --release --test live -- --ignored --nocapture --test-threads 1

# Integration tests on the Linux desktop build under Xvfb, with the testkit's fault server running alongside.
# Expanded reporter: every test's output (the JOURNEY steps) prints as it happens, so a hang shows where it stopped.
# A hang that blocks the app (no Dart timeout can fire) is ended after 10 min without output, with the app's native
# stacks in the log (scripts/with-hang-watch.sh).
test-integration:
    {{heavy}} scripts/with-fault-server.sh scripts/with-hang-watch.sh 600 bash -c 'cd app && xvfb-run -a flutter test integration_test -d linux --reporter expanded --dart-define=GERDTV_FAULT_SERVER="$GERDTV_FAULT_SERVER" --dart-define=GERDTV_MOCK_XC="$GERDTV_MOCK_XC" --dart-define=GERDTV_SCREENS_DIR="$HOME/gerdTV-screens/$(git branch --show-current)"'

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
    step "libmpv harness" "just test-harness"
    step "licences" "just licences"
    step "bench (budgets, ≤ 20 % regression)" "just bench"
    step "integration tests (Linux, Xvfb)" "just test-integration"
    step "Linux release build" "just build-linux"
    echo; echo "PR body lines:"; printf '%s\n' "${lines[@]}"

# What the `linux` CI job runs (.github/workflows/ci.yml).
ci-linux:
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --quiet -- -D warnings
    just test
    just test-harness
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
    # The first-install DMG isn't in latest.json (the updater uses the zip): check it's there and not empty.
    [[ -s "$(ls "$dir"/gerdTV-macos-*.dmg 2>/dev/null | head -1)" ]] || { echo "verify-release: no macOS DMG"; exit 1; }
    echo "macOS DMG present"

# Check that every bundled dependency's licence is GPL-3.0 compatible (scripts/licences.sh).
licences:
    scripts/licences.sh

# [MAC] sessions only: build and run the integration tests on a Mac.
mac-check:
    cd app && flutter build macos --debug
    scripts/with-fault-server.sh bash -c 'cd app && flutter test integration_test -d macos --reporter expanded --dart-define=GERDTV_SOFTWARE_VIDEO=true --dart-define=GERDTV_FAULT_SERVER="$GERDTV_FAULT_SERVER" --dart-define=GERDTV_MOCK_XC="$GERDTV_MOCK_XC"'
