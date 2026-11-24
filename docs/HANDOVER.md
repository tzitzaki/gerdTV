# Handover

## State
- Version 0.261124.54: sort for every list, Settings in five categories, swipe on phones, guide gaps, theme options and a cinematic look.
- Also in .54: gerdTV's own libmpv on Android (libgerdmpv.so) and macOS/iOS (GerdMpv.framework) besides Linux; media_kit's engine stays default.
- Before (0.261123.52): updates install in place, a DMG, Your data, search everywhere, favourites, continue watching, hidden groups, profiles, timeshift.
- media_kit_video is vendored in third_party/ (Apple: libmpv looked up at run time, MPV.swift); the Apple libs packages come from pub.dev.
- CI: a libmpv-apple job builds GerdMpv when its script changes; the android job plays a new libgerdmpv.so on an x86_64 emulator before caching it.
- Live guide check (counts only): with the provider guide 2066 channels show a programme now (2042 before), 2087 with the community DE file.

## Owner decisions
- All questions of session 5 are answered; the standing decisions are in docs/DECISIONS.md.
- Open: which gTV logo is the default? The wordmark is, until you pick one in Settings → Appearance (the pick also changes the icon).
- Open: the TV layout's focus polish needs your feedback from the Shield (what feels wrong with the D-pad).
- Open: start mpv with load-scripts=no in the vendored media_kit (fixes the Linux CI hang for the standard engine)?
- Open: should the Licences screen read the libgerdmpv build files (written by the builds) instead of the hand-written native.txt?
- Open: a brightness swipe on the left half of the player, next to the volume swipe?
- Open: device checks were full: have you done the Mac's install, setup, profiles, keychain and live TV checks? Then they stay deleted.

## Owner one-off jobs
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac (from the DMG), the iPhone and the Shield and go through docs/DEVICE_CHECKS.md.

## Open work
- M3U catch-up (catchup-source templates) when an M3U profile needs it.
- Flaky journey: playback sometimes stalls after leaving the player (app_test.dart "keeps playing"); fix by cause, failing test first.
- A dedicated test for the guide's sticky titles (the screen check's overlap rule no longer catches a hidden running title).
- The own engine as default once it passed the owner's device checks on every platform (DECISIONS: Own libmpv).
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: PIN-locked groups and the TV-layout focus polish.
- Phase 4 TMDB enrichment; Phase 5 recordings and menu bar/tray; lazy VOD details.

## Things to watch
- Player gestures use media_kit's own: no seek swipe on live channels (timeshift keeps its bar); the volume swipe sets mpv's volume, not the system's.
- The community guide presets point at epgshare01, a third party: a file that moves shows as the source's error in Settings → Guide.
- About 1000 provider channels are listed without programmes; they now count as "without guide" and can take a community guide or a mapping.
- GerdMpv on Apple: CI only compiles iOS and plays the macOS slice headless; picture, hwdec and PiP are device checks.
- GerdMpv has no x86_64 iOS simulator slice: an Intel Mac's simulator build would fail to embed it.
- Both libmpvs may be in one Apple process (media_kit links Mpv); the plugin calls only the chosen one, and mpv's ObjC class names may warn twice.
- Linux CI hang: the app blocks at player start in the system libmpv while its Lua scripts start; CI runs integration on the own engine.
- The own Linux libmpv is built in an Ubuntu 24.04 container and must need at most glibc 2.39; the build fails otherwise.
- The own Linux libmpv decodes with VA-API through the DRM render node only (X11 is GPL-only in mpv, 24.04's Wayland is too old).
- The Android TV banner per launcher alias is not in Android's alias docs; if the Shield ignores it, the banner stays the wordmark.
- media_kit has had no release since 12/2025 and ships mpv 0.36 / FFmpeg 6.0 on Apple platforms and Android.
- One media_kit Player per process: a second one misbehaved, and one per screen-check size hung CI's Linux job (#26).
- In the journey, typing into search after the catch-up step doesn't arrive (cause open; a real keyboard is not involved).
- Integration tests take about 9–16 min (the screen check plays video at every size, plus a light pass on the phone).
- Release builds restore CI's Android and libmpv caches from main; a release tagged before main's runs finished builds them cold.
- The version-bump check in scripts/ci-scope.sh trusts the six-digit minor; a dependency versioned 0.YYMMDD.x would slip through as a bump.
- The provider panel once answered an empty VOD list under load; sync keeps the known entries in that case.

## Ideas not chosen
- Seamless reconnect with a second player taking over (costs a second provider connection).
- A persistent macOS Finder icon for the chosen logo (changing the app bundle breaks its code signature).
