# Handover

## State
- Version 0.261122.40: Settings in categories with a search over every setting, four gTV logos that switch the app icon, an orange accent.
- Also new since 0.261122.34: reminders on future programmes (#36) and the in-app updater part 1 in Settings → Updates (#35).
- Before: catch-up, the Licences screen, the TV guide everywhere (grid, now/next in lists, zapping with a banner and channel list).
- Channel lists in four modes with logos from a disk cache; Settings → TV guide with extra XMLTV URLs, offset and mapping; programmes in search.
- A screen check visits every screen on phone, desktop and TV sizes with screenshots in ~/gerdTV-screens/<branch>/.
- Session 3: Block A (0.261122.21), Block B (0.261122.31), catch-up and licences (0.261122.34), this release; fades, guide header, cleartext are open PRs.

## Owner decisions
- All Phase 0 questions are answered; the standing decisions are in docs/DECISIONS.md.
- Open: which gTV logo is the default? The wordmark is, until you pick one in Settings → Appearance (the pick also changes the icon).
- Open: orange seeds the whole theme, so dark surfaces turned warm brown-black. Keep that, or keep neutral surfaces with orange highlights only?
- Open: the logo tile is blue-black (#12121A) and shows as a faint square on the warm surfaces. Recommended: tint the tile to the surface.
- Open: programme search lists running and upcoming first, so a missed show can drop past 100 hits. Recommended: an "Earlier" group.
- Open: `just bench` against a stored baseline gives false alarms on a shared machine. Recommended: measure main and the branch in one run.
- Open: Linux builds of parallel sessions don't take the heavy lock, which skews the bench gate. Recommended: build-linux and test-integration take it.

## Owner one-off jobs
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac, the iPhone and the Shield and go through docs/DEVICE_CHECKS.md (new: the logo and icon switch per device).

## Open work
- Block C: the updater's install step (macOS swap with the sandbox off, Android installer), export/import of user data, own libmpv with an engine switch.
- M3U catch-up (catchup-source templates) when an M3U profile needs it.
- A dedicated test for the guide's sticky titles (the screen check's overlap rule no longer catches a hidden running title).
- Timeshift in the player screen (pause/rewind live, "behind live" label); the core and the harness test are done.
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: favourites, continue watching, hidden groups and PIN, multiple profiles UI, TV-layout focus polish.
- Phase 4 TMDB enrichment; Phase 5 recordings and menu bar/tray; lazy VOD details.

## Things to watch
- The Android TV banner per launcher alias is not in Android's alias docs; if the Shield ignores it, the banner stays the wordmark.
- The iOS alternate icons and the macOS Dock icon could not be checked against Apple's docs here; CI only compiles them.
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- One media_kit Player per process: a second one misbehaved, and one per screen-check size hung CI's Linux job (#26).
- A Linux CI hang in #18 is unexplained; tests now time out after 5 min with their name, a blocked event loop shows as a job cancel.
- Integration tests take about 7–14 min (the screen check plays video at every size); watch it as screens are added.
- Another session on the same machine skews `just bench`: compare against main under the same load before believing a regression.
- Release builds restore CI's Android cache from main; a release tagged before main's android run finished builds cold.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
- A persistent macOS Finder icon for the chosen logo (changing the app bundle breaks its code signature).
