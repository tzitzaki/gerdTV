#!/usr/bin/env bash
# Builds gerdTV's own libmpv (scripts/build-libmpv.sh) inside Ubuntu 24.04, so the result needs no newer glibc than
# the Linux release promises (2.39) whatever the host runs; the packages are installed in the container only.
# Usage: scripts/build-libmpv-container.sh [out-dir]   (default build/libmpv; needs docker)
# Debugging: the stage logs are in <out-dir>/work/; `docker run -it … bash` with the same image gives a shell.
set -euo pipefail
out="${1:-build/libmpv}"
image="ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289"
packages=(ca-certificates curl git build-essential pkg-config meson ninja-build nasm patchelf python3 python3-jinja2
  hwdata libass-dev libva-dev libdrm-dev libegl-dev libgl-dev libpulse-dev libasound2-dev libgnutls28-dev zlib1g-dev)
mkdir -p "$out" # created here, so it belongs to the user, not to the container's root
docker run --rm -v "$PWD:/src" -w /src "$image" bash -c "
  set -e
  apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends ${packages[*]} >/dev/null
  scripts/build-libmpv.sh '$out'
  chown -R $(id -u):$(id -g) '$out'"
