#!/usr/bin/env bash
# Runs the smoke test of gerdTV's own libmpv for Android (scripts/libmpv-android-smoke.c) on a running x86_64
# emulator: builds the test with the NDK against build/libmpv-android/x86_64/libgerdmpv.so, pushes it with the
# library and the testkit's synthetic clip to /data/local/tmp, and runs it. Never against a real device: it refuses
# anything that isn't an emulator (CLAUDE.md: no automated installs on the owner's devices).
# Usage: scripts/test-libmpv-android.sh        (after build-libmpv-android.sh with x86_64; CI starts the emulator)
set -euo pipefail
cd "$(dirname "$0")/.."
ndk="${ANDROID_NDK_HOME:-$(ls -d "$HOME"/sdk/android/ndk/* | sort -V | tail -n 1)}"
cc="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang"
lib=build/libmpv-android/x86_64/libgerdmpv.so
include=build/libmpv-android/work-x86_64/mpv/include
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
"$cc" -I"$include" scripts/libmpv-android-smoke.c -L"$(dirname "$lib")" -lgerdmpv -o "$out/smoke"
qemu="$(adb shell getprop ro.kernel.qemu; adb shell getprop ro.boot.qemu)"
[[ "$qemu" == *1* ]] || { echo "test-libmpv-android: not an emulator"; exit 1; }
adb push "$lib" "$out/smoke" crates/gerdtv-testkit/media/clip.ts /data/local/tmp/ >/dev/null
adb shell "cd /data/local/tmp && chmod 755 smoke && LD_LIBRARY_PATH=/data/local/tmp ./smoke clip.ts" | tee "$out/log"
grep -q '^smoke: ok' "$out/log"
