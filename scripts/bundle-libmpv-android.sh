#!/usr/bin/env bash
# Puts gerdTV's own libmpv (build/libmpv-android/<abi>/libgerdmpv.so, scripts/build-libmpv-android.sh) where Gradle
# packs native libraries (app/android/app/src/main/jniLibs/<abi>/, not committed) and prints the flag that tells the
# app it is there (--dart-define=GERDTV_OWN_LIBMPV=true; app/lib/platform/engine.dart). Prints nothing when the
# library hasn't been built: the APK then has media_kit's engine only.
# Usage: scripts/bundle-libmpv-android.sh <abi>…      (used by `just build-android` and release.yml)
set -euo pipefail
cd "$(dirname "$0")/.."
found=0
for abi in "$@"; do
  lib="build/libmpv-android/$abi/libgerdmpv.so"
  dest="app/android/app/src/main/jniLibs/$abi"
  rm -rf "$dest"
  if [[ -f "$lib" ]]; then
    mkdir -p "$dest" && cp "$lib" "$dest/" && found=1
  fi
done
if [[ $found == 1 ]]; then echo "--dart-define=GERDTV_OWN_LIBMPV=true"; fi
