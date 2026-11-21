# Handover

## State
- Version 0.261121.9: the app starts and loads the Rust core; there is no browsing or player screen yet (Phase 3 builds the UI).
- Core: M3U and Xtream Codes sync into SQLite with FTS5 search, profiles, the library bridge, buffer presets and the playback watchdog.
- Proven on Linux and the macOS CI runner: media_kit plays, the watchdog recovers cut streams and stops on refused ones, the mini player keeps playing.
- Session 1: bootstrap #1, testkit #2 #5, Spike A #3, Spike B #4, core data #6 #7, watchdog #8, wrap-up #9.

## Owner decisions
- Waiting for answers to the Phase 0 question batch (players, Cast, macOS sandbox, git author, session scope, ideas).

## Owner one-off jobs
- Delete the first revision of PR #6's description (it named the dev machine): open the PR, "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there (all seven secrets are uploaded).
- Install this release once on the Mac and the Shield per docs/INSTALL.md and tick the device checks.

## Open work
- Spike C (Google Cast): parked until the owner approves oxicast and its test-only TLS dependencies.
- Phase 2: the Rust libmpv harness against the fault server, timeshift (back buffer), the nightly soak, Stream health in the UI.
- Phase 2: use the remembered URL form and record_health from the player screen once Phase 3 adds it.
- Phase 3: design tokens, layouts per form factor, global search UI, browse, overlay, settings, first-run wizard.
- Phase 1 leftovers: lazy VOD/series info, background refresh timers (24 h playlist), export/import if approved.

## Things to watch
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- A second media_kit Player created in the same process after the first was disposed delivered no events: keep one player for the app's life.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
