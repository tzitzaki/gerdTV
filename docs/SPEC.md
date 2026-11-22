# Specification

What gerdTV does, per platform. Sections fill in as features are built; this is the current state.

## Platforms
| Platform | Status |
|---|---|
| macOS (Apple Silicon) | main target; bootstrap app builds in CI |
| Android TV | second target; debug APK builds in CI |
| iPhone / iPad | third target; unsigned IPA from releases |
| Linux desktop (x64) | supported; the test platform |
| Android phone | ships with the Android build |

## Current behaviour
- **First run:** the provider's Xtream Codes login (server, username, password) or an M3U playlist URL. Connecting runs the first sync; a refused login or an unreachable server is shown under the button and the form stays filled. The login goes to the platform's secure storage only.
- **Start:** the saved account opens from its cached catalogue at once; a background sync refreshes it (a thin bar shows while it runs; a failed sync says so with Retry).
- **Browse:** Live TV, Movies, Series: the provider's groups in provider order with counts, then a group's items (paged, instant filter field); series open their episodes (fetched when opened).
- **Search:** one field finds live channels, movies, series and episodes as you type (prefix per word, umlaut-insensitive, a channel number finds that channel); type chips with counts; Enter plays the top result (a series opens its episodes). `/` or Ctrl/Cmd+F jumps to search on desktop.
- **Player:** full screen with media_kit's controls; the watchdog recovers drops and stalls by itself and shows "Reconnecting (n)…"; a refused stream shows the reason instead of retrying; Space pauses, S or the Stop button stops.
- **Playback keeps going:** only Stop or starting another stream ends it. Leaving the player (Esc/Back) keeps the stream running in the now-playing bar below every screen (live picture, title, watchdog state, Stop); tapping the bar reopens the player without restarting the stream.
- **Picture-in-Picture and background (Android phone and TV):** leaving the app while something plays shrinks it to the system's floating window; with the screen off or in another app the stream keeps playing (a "gerdTV" notification shows while it runs) until Stop.
- **Background and Picture-in-Picture (iPhone/iPad):** sound keeps playing with the screen locked or in another app; the player's PiP button hands the stream to Apple's player in a floating window (live channels and most VOD; `.mkv` movies continue in gerdTV instead), and closing PiP continues in gerdTV.
- **Mini player (desktop):** the player's mini-player button (or P) shrinks the window to a floating, always-on-top picture (on every Space on macOS) with Restore and Stop; drag it anywhere; playback continues.
- **Buffer:** Settings → Playback chooses the profile's preset (Fast zap ~2 s, Balanced ~8 s, Smooth ~30 s, Max smooth ~90 s, Custom 1–300 s); the player's buffer button sets a channel's own preset (applied at once, "Use the default" goes back). The player shows buffered seconds against the target. Adaptive mode (opt-in): a channel that rebuffers more than 3 times in 10 minutes gets one step more and a short notice; never lowered automatically. The cache size follows the channel's measured bitrate.
- **Pause and rewind live:** live channels keep a back buffer (Settings → Playback: off, 30, 60 or 120 min; default 60 on desktop, 30 on phone/TV) on disk, so the player's seek bar can go back.
- **Settings:** update now, last sync, playback (buffer, adaptive mode, timeshift), stream health (every recovery), remove the account, licences, version.
- English and German, following the system language; dark theme.

## Planned for v1 (built phase by phase)
Live TV, movies and series from Xtream Codes or M3U with provider groups; TMDB enrichment; one global search that narrows per keystroke; EPG with a guide grid, programme search, reminders and recordings; a buffer the user chooses and a watchdog that recovers stalled streams without user action; timeshift and catch-up; mini player / Picture-in-Picture; multiple profiles; hidden and PIN-locked groups; Google Cast and AirPlay; an in-app updater.

## Known platform limits
- iOS/iPadOS: no recording (the platform suspends background apps) and no Picture-in-Picture (Apple's PiP needs AVPlayer, not mpv).
- iOS/iPadOS: updates are notified only; the IPA is re-signed and installed by hand.
- Linux: updates are downloaded and verified, then replaced by hand.
