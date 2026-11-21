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
- The app starts, loads the Rust core and shows its greeting, in English or German following the system language.

## Planned for v1 (built phase by phase)
Live TV, movies and series from Xtream Codes or M3U with provider groups; TMDB enrichment; one global search that narrows per keystroke; EPG with a guide grid, programme search, reminders and recordings; a buffer the user chooses and a watchdog that recovers stalled streams without user action; timeshift and catch-up; mini player / Picture-in-Picture; multiple profiles; hidden and PIN-locked groups; Google Cast and AirPlay; an in-app updater.

## Known platform limits
- iOS/iPadOS: no recording (the platform suspends background apps) and no Picture-in-Picture (Apple's PiP needs AVPlayer, not mpv).
- iOS/iPadOS: updates are notified only; the IPA is re-signed and installed by hand.
- Linux: updates are downloaded and verified, then replaced by hand.
