# Handover

## State
- Version VERSION_PLACEHOLDER: reminders, the in-app update check, Earlier in programme search, 150 ms fades, a never-empty guide header.
- Before: catch-up and a complete Licences screen (0.261122.34); the guide grid, list modes, zapping (0.261122.31).
- Android needs no cleartext config any more; background playback and auto-PiP work again since 0.261122.31.
- A screen check visits every screen on phone, desktop and TV with screenshots; a watchdog stops a hung integration run with native stacks.
- Session 3 continues with Block C: updater part 2 (install in place), export/import of user data, own libmpv with an engine switch.

## Owner decisions
- All questions of this session are answered; the standing decisions are in docs/DECISIONS.md.
- Open: `just bench` against a stored baseline gives false alarms on a shared machine. Recommended: measure main and the branch in one run.

## Owner one-off jobs
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac, the iPhone and the Shield and go through docs/DEVICE_CHECKS.md.

## Open work
- Updater part 2: the macOS swap with the sandbox off and Android's package installer (both need device checks).
- Export/import of user data; own libmpv builds for all platforms with an engine switch in Settings.
- A dedicated test for the guide's sticky titles (the screen check's overlap rule no longer catches a hidden running title).
- M3U catch-up (catchup-source templates) when an M3U profile needs it.
- Timeshift in the player screen (pause/rewind live, "behind live" label); the core and the harness test are done.
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: favourites, continue watching, hidden groups and PIN, multiple profiles UI, TV-layout focus polish.
- Phase 4 TMDB enrichment; Phase 5 recordings and menu bar/tray; lazy VOD details.

## Things to watch
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- One media_kit Player per process: a second one misbehaved, and one per screen-check size hung CI's Linux job (#26).
- Linux CI hung four times (#18, #26, #37, #41) with the app blocked; the next hang leaves native stacks in the log (#42).
- In the journey, typing into search after the catch-up step doesn't arrive (cause open; a real keyboard is not involved).
- Integration tests take about 7–10 min (the screen check plays video at every size); watch it as screens are added.
- Another session on the same machine skews `just bench`: compare against main under the same load before believing a regression.
- Release builds restore CI's Android cache from main; a release tagged before main's android run finished builds cold.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
