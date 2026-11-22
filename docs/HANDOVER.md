# Handover

## State
- Version VERSION_PLACEHOLDER: the TV guide everywhere: a grid section, now/next in lists, zapping with a banner and channel list in the player.
- Channel lists in four modes with logos from a disk cache; Settings → Guide with extra XMLTV URLs, offset and mapping; programmes in search.
- Android background playback and auto-PiP work again (since #14 no start reached the platform; fixed in #27).
- A screen check visits every screen on phone, desktop and TV sizes with screenshots in ~/gerdTV-screens/<branch>/.
- Session 3 so far: Block A (0.261122.21), Block B #22–#27; catch-up #30 waits for a green bench, reminders wait for an owner decision.

## Owner decisions
- All Phase 0 questions are answered; the standing decisions are in docs/DECISIONS.md.
- Open: reminders need flutter_local_notifications (pre-approved), but adding it was refused by the permission check: allow it, or in-app only?
- Open: remove Android's cleartext config? Flutter no longer fetches over HTTP; iOS keeps its exception for AVPlayer. Recommended: yes.
- Open: page transitions are Flutter's 300–500 ms, DESIGN.md says at most 150 ms. Recommended: a 150 ms fade for every route.
- Open: the phone guide's header stays empty until a programme is focused. Recommended: show the first row's running programme.
- Open: programme search lists running and upcoming first, so a missed show can drop past 100 hits. Recommended: an "Earlier" group.

## Owner one-off jobs
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac, the iPhone and the Shield and go through docs/DEVICE_CHECKS.md.

## Open work
- Catch-up #30: built and green except the bench, which another session's load skews; mark ready after a quiet green `just bench`.
- Reminders (9b) after the owner's decision; M3U catch-up (catchup-source templates) when an M3U profile needs it.
- Block C: complete licences screen, in-app updater with macOS sandbox off, export/import, own libmpv with an engine switch.
- Timeshift in the player screen (pause/rewind live, "behind live" label); the core and the harness test are done.
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: favourites, continue watching, hidden groups and PIN, multiple profiles UI, TV-layout focus polish.
- Phase 4 TMDB enrichment; Phase 5 recordings and menu bar/tray; lazy VOD details.

## Things to watch
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- One media_kit Player per process: a second one misbehaved, and one per screen-check size hung CI's Linux job (#26).
- A Linux CI hang in #18 is unexplained; tests now time out after 5 min with their name, a blocked event loop shows as a job cancel.
- Integration tests take about 7–10 min (the screen check plays video at every size); watch it as screens are added.
- Another session on the same machine skews `just bench`: compare against main under the same load before believing a regression.
- Release builds restore CI's Android cache from main; a release tagged before main's android run finished builds cold.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
