# Vendored packages

media_kit's video plugin, which gerdTV patches (owner decision: vendored, not a fork on GitHub). It is the pub.dev
release named in its pubspec.yaml, copied unchanged in one commit (the example folder left out), then patched in
commits of their own, so `git log -p third_party/` shows every change. Its licence (MIT) stays in its folder.

- `media_kit_video` 2.0.1: on macOS and iOS the plugin calls libmpv through `MPV.swift`, which looks the functions up
  at run time in the library the app loaded (named in the GERDTV_LIBMPV environment variable, set by
  app/lib/platform/engine.dart), instead of linking Mpv.framework. So the app can run media_kit's libmpv or
  gerdTV's own GerdMpv.framework (Settings → Player engine), which `scripts/embed-libmpv-apple.sh` copies into the
  app without linking it.
- `media_kit_video` 2.0.1: `queryDecoders` no longer re-runs media_kit's library lookup (it fell back to Mpv.framework
  and crashed on GerdMpv's handle), and `MPV.swift` reads GERDTV_LIBMPV with getenv.
- `media_kit_video` 2.0.1, frame path (iOS and macOS, `TextureHW`, `VideoOutput`): mpv's update callback goes straight
  to the worker; a frame is drawn only when mpv has a new one (`mpv_render_context_update`) or the buffers were resized;
  Flutter hears about drawn frames asynchronously; the picture is rendered at most at the screen's pixel size; on iOS
  nothing is drawn while the app is in the background (no GL there).
- `media_kit_video` 2.0.1: `VideoController(create: …)` takes the video output of a player that isn't mpv (gerdTV's
  AVPlayer engine, `app/lib/player/av_player.dart`).
- `media_kit_video` 2.0.1, iOS Picture-in-Picture of mpv's picture: `TextureHW.pipSink` receives every drawn frame
  (the app feeds its PiP layer); in the background with PiP showing (`TextureHW.pipActive`) mpv renders in software at
  PiP size (`useSoftware`, the track re-selected on the new renderer); `Worker.sync`; `MPV.get/setPropertyString`.

Updating it: copy the new release over the folder in one commit, then re-apply the patches (see git log).
