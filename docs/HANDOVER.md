# Handover

## State
- Version 0.261122.21: playback keeps going until Stop, in a now-playing bar, a desktop mini player, Android PiP and in the background.
- Buffer settings are in the app: presets per profile and per channel, opt-in adaptive mode, bitrate-sized cache and the timeshift window.
- The core imports TV guides (XMLTV, provider and extra URLs), matches channels and answers now/next, grid windows and programme search.
- Session 3 so far: Block A #13–#16, guide core #17, release fix #20; the 0.261122.16 release failed (Maven Central 429), this one replaces it.

## Owner decisions
- All Phase 0 questions are answered; the standing decisions are in docs/DECISIONS.md.
- Session 3 plan: Block A playback, Block B the full guide, Block C CI cache, licences screen, updater, export/import and own libmpv.
- Open: remove Android's cleartext config? Flutter no longer fetches over HTTP; iOS keeps its exception for AVPlayer. Recommended: yes.
- Open: page transitions are Flutter's 300–500 ms, DESIGN.md says at most 150 ms. Recommended: a 150 ms fade for every route.
- Open: build the per-form-factor screen check with screenshots (CLAUDE.md asks for it; it doesn't exist yet). Recommended: yes, before the guide grid.

## Owner one-off jobs
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac, the iPhone and the Shield and go through docs/DEVICE_CHECKS.md.

## Open work
- Block B: Settings → Guide and programme search (#19), list modes with logos, then the grid, the mini-guide, catch-up and reminders.
- Block C: complete licences screen, in-app updater with macOS sandbox off, export/import, own libmpv with an engine switch.
- Timeshift in the player screen (pause/rewind live, "behind live" label); the core and the harness test are done.
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: favourites, continue watching, hidden groups and PIN, multiple profiles UI, TV-layout focus polish.
- Phase 4 TMDB enrichment; Phase 5 recordings and menu bar/tray; lazy VOD details.

## Things to watch
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- A second media_kit Player in the same process after the first was disposed delivered no events: the app keeps one player.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.
- The first channels of some provider groups are placeholders that don't play; the player then shows the reason.
- CI checks macOS video with software rendering (the runner VM has no GPU); hardware video on a real Mac is a device check.
- Integration tests tap only hit-testable widgets (`tapReady`): routes and sheets slide in, and on macOS from the right.
- Release builds restore CI's Android cache from main; a release tagged before main's android run finished builds cold.
- `just bench` while other builds run reports false regressions (seen: +39 %); run it on a quiet machine.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
