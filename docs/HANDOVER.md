# Handover

## State
- Version 0.261124.56: movie and series pages with trailers, a track picker, a brightness swipe, Premiumize, Trakt and Simkl, a macOS menu bar mode.
- Also in .56: Account in subcategories, no channel numbers, guide short names, unmatched-channel search, a Release page link, iOS PiP fixes.
- In .55: the own engine no longer crashes on macOS and iOS (a library mix-up in the video plugin), and iOS keeps playing when locked.
- In .54: own libmpv on Android and macOS/iOS besides Linux (media_kit's stays default), sort everywhere, Settings in five categories.
- media_kit_video is vendored in third_party/ (Apple: libmpv looked up at run time, MPV.swift); the Apple libs packages come from pub.dev.
- CI: a libmpv-apple job builds GerdMpv when its script changes; the android job plays a new libgerdmpv.so on an x86_64 emulator before caching it.

## Owner decisions
- Session 6's questions are answered; standing decisions (including no secret in the repo or the app) are in docs/DECISIONS.md.
- Open: Licences: full licence texts per Rust crate, one page grouped by kind, native flags from the build outputs: which of these do you want?
- Open: device checks are full; dropped to fit: the Mac's "stopped movie continues" and "series opens episodes": done, or keep them?
- Open: the TV layout's focus polish needs your feedback from the Shield (what feels wrong with the D-pad).
- Open: start mpv with load-scripts=no in the vendored media_kit (fixes the Linux CI hang for the standard engine)?

## Owner one-off jobs
- Register gerdTV at premiumize.me/registerclient and simkl.com/settings/developer (TV/device type), then `gh variable set` both ids (docs/RELEASING.md).
- For Trakt: create your own app on trakt.tv (Settings → Your API Apps, redirect urn:ietf:wg:oauth:2.0:oob) and enter it in Settings → Account → Trakt.
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac (from the DMG), the iPhone and the Shield and go through docs/DEVICE_CHECKS.md.

## Open work
- M3U catch-up (catchup-source templates) when an M3U profile needs it.
- Flaky journey: playback sometimes stalls after leaving the player (app_test.dart "keeps playing"); fix by cause, failing test first.
- A dedicated test for the guide's sticky titles (the screen check's overlap rule no longer catches a hidden running title).
- The own engine as default once it passed the owner's device checks on every platform (DECISIONS: Own libmpv).
- Trakt/Simkl: import their watch progress into Continue watching (only scrobbling is built); match by ids once TMDB enrichment lands.
- iOS PiP: if it still fails on the device, the player now shows the reason: build the fix from that message.
- Spike C and casting (oxicast), then AirPlay on Apple platforms.
- Phase 3 rest: PIN-locked groups and the TV-layout focus polish.
- Phase 4 TMDB enrichment; Phase 5 recordings and menu bar/tray; lazy VOD details.

## Things to watch
- Trailers play in YouTube's embed in a web view; YouTube refuses embeds without a referrer (error 153), so gerdTV sends its own origin.
- Tracking matches by cleaned title and year; a provider name that keeps decorations clean_title misses is sent as it is (tracking.rs).
- Player gestures use media_kit's own: no seek swipe on live channels (timeshift keeps its bar); the volume swipe sets mpv's volume, not the system's.
- The community guide presets point at epgshare01, a third party: a file that moves shows as the source's error in Settings → Guide.
- About 1000 provider channels are listed without programmes; they now count as "without guide" and can take a community guide or a mapping.
- Own engines in CI: Android and macOS play the testkit clip headless (smoke: ok); iOS only compiles; picture, hwdec and PiP are device checks.
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
