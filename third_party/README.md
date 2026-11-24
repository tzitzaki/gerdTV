# Vendored packages

media_kit's video plugin, which gerdTV patches (owner decision: vendored, not a fork on GitHub). It is the pub.dev
release named in its pubspec.yaml, copied unchanged in one commit (the example folder left out), then patched in
commits of their own, so `git log -p third_party/` shows every change. Its licence (MIT) stays in its folder.

- `media_kit_video` 2.0.1: on macOS and iOS the plugin calls libmpv through `MPV.swift`, which looks the functions up
  at run time in the library the app loaded (named in the GERDTV_LIBMPV environment variable, set by
  app/lib/platform/engine.dart), instead of linking Mpv.framework. So the app can run media_kit's libmpv or
  gerdTV's own GerdMpv.framework (Settings → Player engine), which `scripts/embed-libmpv-apple.sh` copies into the
  app without linking it.

Updating it: copy the new release over the folder in one commit, then re-apply the patches (see git log).
