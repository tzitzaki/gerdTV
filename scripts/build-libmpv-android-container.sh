#!/usr/bin/env bash
# Builds gerdTV's own libmpv for Android (scripts/build-libmpv-android.sh) inside Ubuntu 24.04 with the host's NDK
# mounted read-only, so the build tools (meson, nasm, patchelf …) come from the container, whatever the host has.
# Usage: scripts/build-libmpv-android-container.sh [out-dir] [abi…]   (default build/libmpv-android, arm64-v8a x86_64;
# needs docker and the NDK in ANDROID_NDK_HOME or ~/sdk/android/ndk)
# Debugging: the stage logs are in <out-dir>/work-<abi>/.
set -euo pipefail
out="${1:-build/libmpv-android}"
shift || true
abis=("${@:-arm64-v8a x86_64}")
ndk="${ANDROID_NDK_HOME:-$(ls -d "$HOME"/sdk/android/ndk/* | sort -V | tail -n 1)}"
image="ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289"
packages=(ca-certificates curl git xz-utils bzip2 build-essential cmake ninja-build meson nasm patchelf pkg-config python3
  python3-jinja2)
mkdir -p "$out" # created here, so it belongs to the user, not to the container's root
docker run --rm -v "$PWD:/src" -v "$ndk:/ndk:ro" -e ANDROID_NDK_HOME=/ndk -w /src "$image" bash -c "
  set -e
  apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends ${packages[*]} >/dev/null
  for abi in ${abis[*]}; do scripts/build-libmpv-android.sh '$out' \$abi; done
  chown -R $(id -u):$(id -g) '$out'"
