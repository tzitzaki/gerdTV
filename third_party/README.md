# Vendored packages

media_kit's packages that gerdTV patches (owner decision: vendored, not a fork on GitHub). Each one is the pub.dev
release named in its pubspec.yaml, copied unchanged in one commit (the example folders left out), then patched in
commits of their own, so `git log -p third_party/` shows every change. Their licence (MIT) stays in each folder.

- `media_kit_video` 2.0.1: on macOS and iOS the video plugin looks up libmpv's functions at run time instead of
  linking Mpv.framework, so the app can load media_kit's libmpv or gerdTV's own (Settings → Player engine).
- `media_kit_libs_macos_video`, `media_kit_libs_ios_video` 1.1.4: unchanged; `scripts/bundle-libmpv-apple.sh` copies
  GerdMpv.xcframework into their `Frameworks/` folder (not committed), which their podspecs embed.

Updating one: copy the new release over the folder in one commit, then re-apply the patches (see git log).
