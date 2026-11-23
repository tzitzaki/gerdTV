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

# gerdTV's own libmpv into build/libmpv (scripts/build-libmpv.sh inside an Ubuntu 24.04 container, needs docker):
# about 15 min; the downloaded sources stay in build/libmpv/work. The Linux build bundles it when it is there
# (app/linux/CMakeLists.txt).
libmpv:
    {{heavy}} scripts/build-libmpv-container.sh build/libmpv

# The harness on the own build: the test binary links libmpv.so.2, and links of that name in front of the system's
# point it at libgerdmpv.so (the same mechanism the app uses, app/linux/runner/main.cc).
test-harness-gerdmpv: _gerdmpv-links
    LD_LIBRARY_PATH="$PWD/build/libmpv/as-system" just test-harness

# The integration tests with the own build loaded by the whole app (the video plugin links libmpv.so.2 itself);
# first proof that the plugin really resolves it, so a silent fallback to the system's libmpv can't pass.
test-integration-gerdmpv: _gerdmpv-links
    cd app && flutter build linux --debug >/dev/null
    LD_LIBRARY_PATH="$PWD/build/libmpv/as-system" ldd app/build/linux/x64/debug/bundle/lib/libmedia_kit_video_plugin.so \
      | grep -q "libmpv.so.2 => $PWD/build/libmpv/as-system/" || { echo "the video plugin doesn't resolve libgerdmpv"; exit 1; }
    LD_LIBRARY_PATH="$PWD/build/libmpv/as-system" just test-integration

_gerdmpv-links:
    mkdir -p build/libmpv/as-system
    ln -sfn ../libgerdmpv.so build/libmpv/as-system/libmpv.so.2
    ln -sfn ../libgerdmpv.so build/libmpv/as-system/libmpv.so

# The soak: GERDTV_SOAK_MINUTES (default 30) of playback with random faults; every fault must recover (nightly).
soak:
    cargo test -q -p gerdtv-testkit --release --test libmpv_watchdog soak -- --ignored --nocapture

# The suites the changes since <base> can affect (the pre-push hook runs this).
test-affected base="origin/main":
    scripts/test-affected.sh {{base}}

# The core's performance budgets, A/B: origin/main's core and this tree's are measured back to back under the heavy
# lock, and more than 20 % slower than main fails (owner decision: a stored baseline drifted with the machine's load,
# e.g. +110 % on unchanged code). Main's side runs in a temporary detached worktree with its own criterion folder.
# With the core and Cargo.lock unchanged against main there is nothing to compare: the benchmarks run once (they
# still have to work; the nightly on main takes this path).
# Lenient: a benchmark that main doesn't have yet is measured, not compared.
bench:
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch -q origin main || true
    # A shallow CI checkout may have no origin/main: then HEAD stands in (nothing to compare).
    base="$(git rev-parse -q --verify origin/main || git rev-parse HEAD)"
    if git diff --quiet "$base" -- crates/gerdtv-core Cargo.lock; then
      echo "bench: core unchanged against main; measuring without a comparison"
      out="$(CRITERION_HOME="$(mktemp -d)" {{heavy}} cargo bench -q -p gerdtv-core --bench budgets 2>&1)" ||
          { echo "$out"; exit 1; }
      grep -E 'time:' <<<"$out" || true
      exit 0
    fi
    main="$(mktemp -d)"
    export CRITERION_HOME="$main/criterion"
    # Main's side builds into its own lasting target folder (dependencies stay built between runs). Never share
    # this tree's: cargo names a workspace crate's output the same whatever folder its source is in, so one side
    # would silently reuse the other's binary (seen: a deliberate 3 ms slowdown measured as 18 % faster).
    main_target="$HOME/.cache/gerdtv-bench-main-target"
    trap 'rm -rf "$main"; git worktree prune' EXIT
    git worktree add -q --detach "$main/tree" "$base"
    out="$({{heavy}} bash -c "cd '$main/tree' && CARGO_TARGET_DIR='$main_target' cargo bench -q -p gerdtv-core --bench budgets -- --save-baseline main >/dev/null \
      && cd '$PWD' && cargo bench -q -p gerdtv-core --bench budgets -- --baseline-lenient main --noise-threshold 0.20" 2>&1)" ||
        { echo "$out"; exit 1; }
    grep -E 'time:|change:|regressed|improved' <<<"$out" || true
    ! grep -q "Performance has regressed" <<<"$out"

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
    just test-harness-gerdmpv
    just l10n
    cd app && flutter analyze
    just licences
    # Integration tests only on gerdTV's own libmpv (owner decision): the system libmpv's Lua scripts sometimes
    # deadlock media_kit's start in CI (main thread in mpv_hook_add / mpv_get_property while the script threads
    # start), and media_kit sets no load-scripts=no before mpv_initialize. The own build has no Lua.
    just test-integration-gerdmpv
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
