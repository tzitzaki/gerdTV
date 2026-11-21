# Decisions

Standing owner decisions not visible in code; one line each. Superseded lines are replaced.

- Targets in priority order: macOS (Apple Silicon), Android TV, iPhone/iPad; Linux desktop is the dev/test platform and supported; Android phone ships with Android; no Windows, no tvOS.
- Stack: Flutter stable (pinned in `app/FLUTTER_VERSION`) + media_kit (libmpv everywhere) + a Rust core through flutter_rust_bridge v2.
- Standalone apps now, a home hub later: every device runs the full core; user data uses stable content keys and `updated_at` so a hub can sync it later.
- Crates: `gerdtv-core` (all logic), `gerdtv-api` (bridge surface only; package `gerdtv_api` because Cargokit names the native library after it), `gerdtv-testkit`, `gerdtv-release`.
- Player libraries (Spike A): media_kit 1.2.6 with the upstream `media_kit_libs_video` packages on every platform; the pub.dev forks are abandoned and the newer mpv_kit is too young to adopt.
- Desktop mini player (Spike B): the main window shrinks into a borderless, always-on-top window (window_manager's native API), so the same engine and player keep playing; no second window.
- The playback watchdog is a pure Rust state machine; a small Dart adapter feeds it mpv events and runs its commands.
- Pre-approved Rust deps: tokio, reqwest (rustls, gzip, stream), serde/serde_json, quick-xml, flate2, rusqlite (bundled, FTS5), tracing (+ subscriber, appender), thiserror, one of time/chrono, mdns-sd, one Google Cast crate (Spike C), flutter_rust_bridge, ed25519-dalek + sha2, criterion (dev), libmpv2 (dev, testkit only).
- Pre-approved Dart deps: media_kit (+ media_kit_video and the chosen libs packages), flutter_rust_bridge, path_provider, flutter_secure_storage, window_manager, tray_manager, launch_at_startup, flutter_local_notifications, flutter_lints; plus Flutter's first-party flutter_localizations, intl (required by gen-l10n) and material_ui (Material moved out of the SDK).
- State management with `ChangeNotifier`/`ValueListenable`, navigation with `Navigator`/`Router`; images fetched and disk-cached by the core, shown with `Image.file`.
- Native code only as small, commented Swift/Kotlin platform channels; no third-party native libraries.
- The Rust bridge is integrated with Cargokit (flutter_rust_bridge's default backend), not Dart native-assets hooks.
- Sources: Xtream Codes first, M3U/M3U8 as fallback, any number of XMLTV URLs per profile.
- Secrets (provider credentials, TMDB key, PIN) live in `flutter_secure_storage`, are held only in memory by the core, never in logs.
- Casting: Google Cast from every platform in the core; AirPlay from Apple platforms via AVKit/AVPlayer.
- Recording in the core as direct stream capture; desktop while the app runs (also menu-bar/tray only), Android via a foreground service, none on iOS.
- CI only on GitHub's free standard runners (`ubuntu-latest`, `macos-latest`); no self-hosted or larger runners.
- Releases: one per wrap-up from `release.yml`; macOS signed with a stable self-signed certificate; Android with the release keystore; an unsigned iOS IPA; a signed `latest.json` for the in-app updater.
- No automated installs on the owner's devices; the owner installs every first copy.
- UI strings in English and German via gen-l10n; the UI follows the system language; the name is spelled "gerdTV" everywhere visible.
