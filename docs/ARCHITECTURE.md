# Architecture

## Crates
- `crates/gerdtv-core`: all logic, no Flutter dependency, tested headless on Linux.
- `crates/gerdtv-api` (package `gerdtv_api`): the flutter_rust_bridge surface; types, async functions, event streams, no logic.
- `crates/gerdtv-testkit`: synthetic data, mock servers, fault injection, and the repository rule tests (`tests/repo_rules.rs`).
- `crates/gerdtv-release`: update key generation, `latest.json` assembly, signing and verification (CI and `just verify-release`).

## The seam (Rust ↔ Flutter)
- `app/flutter_rust_bridge.yaml` points the codegen at `crates/gerdtv-api`; `just codegen` writes the Dart side to `app/lib/src/rust`.
- `app/rust_builder` is a Flutter FFI plugin using Cargokit: every Flutter build (Linux, macOS, Android, iOS) compiles `gerdtv_api` for its targets and bundles `libgerdtv_api`.
- `RustLib.init()` loads the library before the first frame. Widget tests replace it with `RustLib.initMock` and a fake (`app/test/support/fake_core.dart`), so they need no native build.
- Debug: "Failed to load dynamic library" at start means Cargokit didn't build or bundle the library; build with `-v` and look for the Cargokit step.

## Playback pipeline
Phase 2. media_kit (libmpv) plays; mpv options for the buffer presets are set through media_kit's native player properties; the Rust watchdog decides reloads. The option mapping per libmpv version lives here once Spike A has verified it.

## Native libraries
libmpv and FFmpeg come with the media_kit libs packages chosen in Spike A; their versions, licences and build flags are listed here and in the in-app Licences screen.

## Platform channels
None yet. Each one lands here with its purpose, its Swift/Kotlin file and its Dart counterpart.
