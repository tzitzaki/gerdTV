# Handover

## State
- On main since 0.261123.52, not released (CI only): CI runs only the areas a change touches; a session is one PR, a commit per feature.
- Version 0.261123.52: updates install in place, a DMG for the first Mac install, and Settings → Your data (export and import as one JSON file).
- Also in .52: search in every section, favourites, continue watching, hidden groups, profiles, the timeshift UI and Android voice search.
- Also in .52: gerdTV's own libmpv on Linux (mpv 0.42.0, FFmpeg 9.1) in Settings → Playback → Player engine; the standard engine stays default.
- Before (0.261123.43): Earlier in programme search, 150 ms fades, a never-empty guide header, no Android cleartext config, a CI hang watchdog.
- Before: settings in categories, gTV logos, reminders, the updater's download, catch-up, the Licences screen and the full TV guide.
- `just bench` compares main and the branch back to back in one run; a screen check visits every screen with screenshots in ~/gerdTV-screens/.
- Session 3 is done (Blocks A, B and C, up to 0.261123.52); the CI session after it changed only CI, release notes and the dev loop.

## Owner decisions
- All Phase 0 questions are answered; the standing decisions are in docs/DECISIONS.md.
- Open: which gTV logo is the default? The wordmark is, until you pick one in Settings → Appearance (the pick also changes the icon).
- Open: orange seeds the whole theme, so dark surfaces turned warm brown-black. Keep that, or keep neutral surfaces with orange highlights only?
- Open: Linux builds of parallel sessions don't take the heavy lock, which skews the bench. Recommended: build-linux and test-integration take it.
- Open: own libmpv on macOS/iOS needs a media_kit_video fork (its plugin links Mpv.framework directly). Fork it, or keep Apple on media_kit's build?
- Open: the TV layout's focus polish needs your feedback from the Shield (what feels wrong with the D-pad).

## Owner one-off jobs
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac (from the DMG), the iPhone and the Shield and go through docs/DEVICE_CHECKS.md.
- Mac: the first start without the sandbox must keep profiles, favourites and the login; then try Settings → Updates → Install and restart once.

## Open work
- Own libmpv on Android: build it like Linux (one library, own name) and load it for the whole process (the plugin links libmpv itself).
- Own libmpv on macOS and iOS, after the fork question above.
- M3U catch-up (catchup-source templates) when an M3U profile needs it.
- A dedicated test for the guide's sticky titles (the screen check's overlap rule no longer catches a hidden running title).
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: PIN-locked groups and the TV-layout focus polish.
- Phase 4 TMDB enrichment; Phase 5 recordings and menu bar/tray; lazy VOD details.

## Things to watch
- Linux CI hang: the app blocks at player start in the system libmpv while its Lua scripts start (stacks in runs 45176489097, 45184978904).
- So Linux CI runs the integration tests on the own libmpv only (no Lua); the standard engine keeps the harness. Users could still hit it.
- The own libmpv is built in an Ubuntu 24.04 container and must need at most glibc 2.39; the build fails otherwise (CI's runner is 26.04).
- The own libmpv decodes with VA-API through the DRM render node only (X11 is GPL-only in mpv, 24.04's Wayland is too old for mpv 0.42).
- The Android TV banner per launcher alias is not in Android's alias docs; if the Shield ignores it, the banner stays the wordmark.
- The iOS alternate icons and the macOS Dock icon could not be checked against Apple's docs here; CI only compiles them.
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- One media_kit Player per process: a second one misbehaved, and one per screen-check size hung CI's Linux job (#26).
- In the journey, typing into search after the catch-up step doesn't arrive (cause open; a real keyboard is not involved).
- Integration tests take about 8–16 min (the screen check plays video at every size); watch it as screens are added.
- Release builds restore CI's Android cache from main; a release tagged before main's android run finished builds cold.
- New branches restore main's libmpv and linux caches (warm-caches job); right after a key change on main, a branch's first run builds cold.
- The version-bump check in scripts/ci-scope.sh trusts the six-digit minor; a dependency versioned 0.YYMMDD.x would slip through as a bump.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
- A persistent macOS Finder icon for the chosen logo (changing the app bundle breaks its code signature).
- Patching media_kit to start mpv with load-scripts=no (would fix the hang for the standard engine; the own engine in CI was chosen instead).
