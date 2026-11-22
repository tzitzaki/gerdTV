# Handover

## State
- Version 0.261122.12: the first usable app: set up an account, browse Live TV, Movies and Series, search as you type, play with the watchdog.
- Phase 2 is complete: libmpv harness for every fault, timeshift in the core, continuous live test stream, nightly 30-minute soak.
- The core has M3U and Xtream Codes sync, FTS5 search, profiles, schema migrations with backups, and buffer presets.
- Session 1: #1–#9 (bootstrap to the first release); session 2: Phase 2 #10, MVP app #11, wrap-up #12.

## Owner decisions
- Still open from the Phase 0 batch: 1 media_kit builds, 2 exact pins, 5 macOS sandbox, 6 git author, 9–14 ideas.
- Decided: Cast via oxicast behind gerdTV's own interface, no fake receiver in the test kit (Cast is checked by hand on the Shield).

## Owner one-off jobs
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac, the iPhone and the Shield and go through docs/DEVICE_CHECKS.md.

## Open work
- Timeshift in the player screen (pause/rewind live, "behind live" label); the core and the harness test are done.
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: favourites, continue watching, hidden groups and PIN, multiple profiles UI, TV-layout focus polish, mini player in the UI.
- Phase 4: EPG and guide, TMDB enrichment; Phase 5: recordings, menu bar/tray; the in-app updater (approved to come early).
- Lazy VOD details, background refresh timers, logo disk cache in the core.

## Things to watch
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- A second media_kit Player in the same process after the first was disposed delivered no events: the app keeps one player.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.
- The first channels of some provider groups are placeholders that don't play; the player then shows the reason.
- The criterion baseline was recorded from a branch: run `just bench-save` on main in the next session.
- CI checks macOS video with software rendering (the runner VM has no GPU); hardware video on a real Mac is a device check.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
