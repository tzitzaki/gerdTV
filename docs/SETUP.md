# Setup: toolchains, building, CI

## Toolchains (Linux dev machine)
- Debian/Ubuntu packages: `clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-14-dev libmpv-dev mpv libayatana-appindicator3-dev xvfb xauth unzip zip jq just openjdk-21-jdk-headless`.
- Rust via rustup (minimal profile + clippy, rustfmt); the compiler version is pinned in `rust-toolchain.toml`. Android targets: `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`. Tools: `cargo install cargo-ndk flutter_rust_bridge_codegen --locked` (codegen version = the `flutter_rust_bridge` version in `app/pubspec.yaml`).
- Flutter stable at the version in `app/FLUTTER_VERSION` (`git clone -b <version> https://github.com/flutter/flutter`), then `flutter config --no-analytics`, `flutter precache --linux --android`.
- Android: the "command line tools only" package unpacked to `$ANDROID_HOME/cmdline-tools/latest`, then `sdkmanager "platform-tools"`; the first Android build fetches the SDK platform, build tools and NDK it needs. `ANDROID_HOME` and the tool folders on `PATH`.
- `just doctor` prints every version and flags what's missing; `flutter doctor -v` must tick Linux and Android.
- Once per clone: `git config core.hooksPath .githooks` (the pre-push hook: denylist check + `just test-affected`).

## macOS (for `[MAC]` sessions only)
Full Xcode (opened once), `brew install rustup just cocoapods`, rustup as above, Flutter as above, then `just mac-check`.

## Building
- `just test` (Rust + Flutter unit/widget tests), `just test-integration` (Linux build under Xvfb), `just ready` (every gate before a PR is marked ready).
- `just build-linux`, `just build-android` (debug APK, arm64). Release builds come only from `.github/workflows/release.yml`.
- After changing `crates/gerdtv-api`: `just codegen` regenerates `app/lib/src/rust`. The native library is built by Cargokit (`app/rust_builder`) as part of every Flutter build.

## CI
- `.github/workflows/ci.yml` on every pull request push (a newer push cancels the older run): jobs `linux` (fmt, clippy, Rust tests, analyze, Flutter tests, licences, Linux build + integration tests under Xvfb), `macos` (macOS build + integration tests), `android` (debug APK). A first step in each job detects a docs-only change and ends the job green at once.
- `.github/workflows/nightly.yml` (02:30 UTC + manual): everything long (all integration tests now; soak and benchmarks as they arrive).
- Hardening: only `ubuntu-latest`/`macos-latest` (free standard runners); only GitHub-owned actions pinned by commit SHA; `permissions: contents: read` by default; `pull_request`, never `pull_request_target`; no secrets outside the `release` environment. `just test-docs` enforces the runner and action rules.
- Flutter is installed in CI by cloning the pinned tag (no third-party setup action); the Rust toolchain comes from `rust-toolchain.toml` via the runner's rustup.
