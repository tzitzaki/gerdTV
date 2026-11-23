# Setup: toolchains, building, CI

## Toolchains (Linux dev machine)
- Debian/Ubuntu packages: `clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-14-dev libmpv-dev mpv libayatana-appindicator3-dev libsecret-1-dev xvfb xauth unzip zip jq just openjdk-21-jdk-headless`; for gerdTV's own libmpv (`just libmpv`) also `meson nasm patchelf python3-jinja2 libass-dev libva-dev libdrm-dev libegl-dev libgl-dev libpulse-dev libasound2-dev libgnutls28-dev zlib1g-dev libx11-dev libxext-dev libxpresent-dev libxrandr-dev libxss-dev libwayland-dev wayland-protocols libxkbcommon-dev`.
- Rust via rustup (minimal profile + clippy, rustfmt); the compiler version is pinned in `rust-toolchain.toml`. Android targets: `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`. Tools: `cargo install cargo-ndk flutter_rust_bridge_codegen --locked` (codegen version = the `flutter_rust_bridge` version in `app/pubspec.yaml`).
- Flutter stable at the version in `app/FLUTTER_VERSION` (`git clone -b <version> https://github.com/flutter/flutter`), then `flutter config --no-analytics`, `flutter precache --linux --android`.
- Android: the "command line tools only" package unpacked to `$ANDROID_HOME/cmdline-tools/latest`, then `sdkmanager "platform-tools"`; the first Android build fetches the SDK platform, build tools and NDK it needs. `ANDROID_HOME` and the tool folders on `PATH`.
- `just doctor` prints every version and flags what's missing; `flutter doctor -v` must tick Linux and Android.
- Once per clone: `git config core.hooksPath .githooks` (the pre-push hook: denylist check + `just test-affected`).

## macOS (for `[MAC]` sessions only)
Full Xcode (opened once), `brew install rustup just cocoapods`, rustup as above, Flutter as above, then `just mac-check`.

## Live tests
`just test-live` runs the opt-in checks against a real Xtream Codes account from `GERDTV_XC_SERVER`, `GERDTV_XC_USER` and `GERDTV_XC_PASS` (and `GERDTV_TMDB_KEY` once TMDB lands). It prints counts and timings only. Never paste its environment anywhere.

## Building
- `just test-harness` (libmpv driven by the watchdog against the fault server, about 2 min; `just test-harness-gerdmpv` and `just test-integration-gerdmpv` run the same on gerdTV's own build from `just libmpv`), `just soak` (30 min), `just test-epg-budget` (full-scale guide import), `just bench` (the core's performance budgets, compared with the saved baseline), `just test` (Rust + Flutter unit/widget tests), `just licences` (every bundled library is GPL-3.0 compatible, and the Licences screen's crate list is current: after a dependency change run `scripts/licences.sh --write`), `just test-integration` (Linux build under Xvfb; a run without output for 10 min is stopped with the app's native stacks in the log, `scripts/with-hang-watch.sh`: the journeys and the screen check, which visits every screen on phone, desktop and TV sizes and saves a screenshot of each to `~/gerdTV-screens/<branch>/`), `just ready` (every gate before a PR is marked ready).
- After changing a logo's drawing: `just logos` renders the Android, iOS and macOS icon files (commit them) and a preview sheet, logos/preview.png in the app's build folder.
- `just build-linux`, `just build-android` (debug APK, arm64). Release builds come only from `.github/workflows/release.yml`.
- After changing `crates/gerdtv-api`: `just codegen` regenerates `app/lib/src/rust`. The native library is built by Cargokit (`app/rust_builder`) as part of every Flutter build.

## CI
- `.github/workflows/ci.yml` on every pull request push (a newer push cancels the older run): jobs `linux` (fmt, clippy, Rust tests, analyze, Flutter tests, licences, Linux build + integration tests under Xvfb), `macos` (macOS build + integration tests), `android` (debug APK). A first step in each job detects a docs-only change and ends the job green at once. Pushes to `main` run only `android`, which saves its Gradle, pub and cargo cache where release tags can restore it (`release.yml` restores it before the APK build).
- `.github/workflows/nightly.yml` (02:30 UTC + manual): everything long: the linux CI job's checks, `just soak` (30 min of random faults), the full-scale guide import budget and `just bench`.
- Hardening: only `ubuntu-latest`/`macos-latest` (free standard runners); only GitHub-owned actions pinned by commit SHA; `permissions: contents: read` by default; `pull_request`, never `pull_request_target`; no secrets outside the `release` environment. `just test-docs` enforces the runner and action rules.
- Flutter is installed in CI by cloning the pinned tag (no third-party setup action); the Rust toolchain comes from `rust-toolchain.toml` via the runner's rustup.
