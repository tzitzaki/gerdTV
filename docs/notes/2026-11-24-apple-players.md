# Apple players: iOS/macOS 27, no rebuffer between modes, full timeshift

Started 10:40. One branch (feat/apple-27-pip), one PR, one release at the end.

## Decisions (owner)
- iOS and macOS deployment targets 27.0; the Mac is Apple Silicon only (the x86_64 slice goes).
- Live on Apple: AVPlayer, fed by a local HLS from the Rust core (full timeshift, invisible reconnects).
- VOD stays on mpv; iOS PiP shows mpv's own frames (software render at PiP size in the background).
- Swiping to Home floats the player by itself; the PiP window has Apple's controls (play/pause, skip).
- Faster mpv frame path on iOS and macOS; fast scalers on iPhone/iPad.
- Not chosen: a Vulkan render path (mpv 0.42 has no Vulkan render API, mpv#18343).

## Steps
1. Targets 27, arm64 only.
2. Background without PiP: video off, sound on, no reconnect.
3. Lean mpv frame path (vendored media_kit, iOS and macOS).
4. Local HLS in the core (src/hls.rs).
5. AVPlayer engine for live.
6. VOD PiP from mpv's frames (iOS).
7. Docs.
8. Wrap-up and release.

## Progress
- 10:40 step 1 started.
