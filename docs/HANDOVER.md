# Handover

## State
- Version 0.261127.65: OpenSubtitles logins work for VIP accounts (calls go to the host the login names). Before, 0.261126.63: the features other players have.
- Also: own groups and names, Android TV home screen and refresh rate, macOS media keys, account expiry, User-Agent; AirPlay is still open.
- media_kit_video is vendored in third_party/ (Apple: libmpv looked up at run time, MPV.swift); the Apple libs packages come from pub.dev.
- CI: a libmpv-apple job builds GerdMpv when its script changes; the android job plays a new libgerdmpv.so on an x86_64 emulator before caching it.

## Owner decisions
- Session 7's questions are answered; standing decisions (including no secret in the repo or the app) are in docs/DECISIONS.md.
- Open: Licences: full licence texts per Rust crate, one page grouped by kind, native flags from the build outputs: which of these do you want?
- Open: the TV layout's focus polish needs your feedback from the Shield (what feels wrong with the D-pad).
- Open: start mpv with load-scripts=no in the vendored media_kit (fixes the Linux CI hang for the standard engine)?
- Open: reorder channels inside the provider's groups too, or only inside your own groups as now?

## Owner one-off jobs
- Register gerdTV at premiumize.me/registerclient and simkl.com/settings/developer (TV/device type), then `gh variable set` both ids (docs/RELEASING.md).
- For Trakt: create your own app on trakt.tv (Settings → Your API Apps, redirect urn:ietf:wg:oauth:2.0:oob) and enter it in Settings → Account → Trakt.
- Enter your TMDB key and, if you want subtitles online, an OpenSubtitles key (opensubtitles.com → API consumers) in Settings → Account.
- Delete the release-less tag of the failed run: `git push origin --delete v0.261122.16` (the notes skip it either way; I was not allowed to delete it).
- Delete the first revision of PR #6's description (it named the dev machine): "edited", oldest revision, "Delete revision from history".
- Move the signing files from the private config folder into the password manager, then delete them there.
- Install this release on the Mac (from the DMG), the iPhone and the Shield and go through docs/DEVICE_CHECKS.md (a housekeeping round is planned).

## Open work
- [MAC] AirPlay: on AVPlayer's external playback, restart live with the local HLS on the network address (back to 127.0.0.1 after); needs a video receiver.
- [DEVICE] Android recordings while gerdTV is closed: try a start by the exact alarm alone (a headless engine) once the notification path is checked.
- Trakt: import its watch progress like Simkl's (only scrobbling, now with TMDB ids, is built for Trakt).
- Simkl's import is tested on a mock only: check it live once the client id is registered.
- M3U catch-up (catchup-source templates) when an M3U profile needs it.
- A dedicated test for the guide's sticky titles (the screen check's overlap rule no longer catches a hidden running title).
- The own engine as default once it passed the owner's device checks on every platform (DECISIONS: Own libmpv).
- Apple minimums 27.0 once `macos-latest` runs macOS 27 (owner decision; Xcode 27 is not on it yet).
- [DEVICE] Mac: on the first release with #61 (0.261125.62) allow the last prompts (Always Allow), restart; no prompt then or after the next update = fixed.
- [DEVICE] iPhone/iPad/Mac: the AVPlayer and PiP checks in docs/DEVICE_CHECKS.md; black or a long freeze: send the log ("TextureHW: first picture").
- The TV-layout focus polish; lazy VOD details; the menu bar's tray on Linux.

## Things to watch
- oxicast is pre-1.0 and pinned exactly: an update may change its API; Cast is checked by hand only (no fake receiver, owner decision).
- Cast's live fallback serves gerdTV's local HLS on this device's network address (random token, CORS) while it casts.
- Recordings and casting each take a provider connection; the account's limit decides what still plays (recordings win after a notice).
- Deinterlacing switches mpv to copy-back decoding while on: more power use; 1080i smoothness is a device check.
- TMDB: 18 of 20 real movies matched by the panel's TMDB id in the live check; the cache keeps answers 30 days.
- Trailers play in YouTube's embed in a web view; YouTube refuses embeds without a referrer (error 153), so gerdTV sends its own origin.
- Tracking matches by cleaned title and year unless TMDB's id is known; a name clean_title misses is sent as it is (tracking.rs).
- Player gestures use media_kit's own: no seek swipe on live channels (timeshift keeps its bar); the volume swipe sets mpv's volume, not the system's.
- Guide names are judged by country code; a provider without codes in its names falls back to the sources' order.
- With Apple's player chosen, a channel starts once its local HLS has three segments (~6 s): slower zapping than mpv's Fast zap.
- Background PiP switches mpv to software rendering and decoding: a short freeze on leaving and returning; 4K HEVC may stutter there.
- German public channels send no IDR frames (open GOP): with Apple's player, segments start on recovery-point I-frames.
- One media_kit Player per process: a second one misbehaved, and one per screen-check size hung CI's Linux job (#26).
- flutter_secure_storage_linux crashes the app when deleting a key that was never written: delete only what exists (Session.removeProfile).

## Ideas not chosen
- Sleep timer, playback speed, search across accounts, multiview, device sync, downloads and skip intro (session 7's comparison).
- Apple Developer ID (99 USD a year): Keychain tied to the team ID, notarized; possible later step (docs/RELEASING.md).
- The provider's short EPG per channel, and an own iptv-org grabber on a server.
- Seamless reconnect with a second player taking over (costs a second provider connection).
- A persistent macOS Finder icon for the chosen logo (changing the app bundle breaks its code signature).
- A Vulkan render path for mpv (mpv 0.42 has no Vulkan render API, mpv#18343; it would be our own mpv patch).
