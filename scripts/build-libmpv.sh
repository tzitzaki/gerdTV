#!/usr/bin/env bash
# gerdTV's own libmpv (owner decision, docs/DECISIONS.md): current mpv with FFmpeg and libplacebo linked in, LGPL
# configuration, as ONE self-contained shared library named libgerdmpv.so, so it can sit next to the engine media_kit
# bundles (or the system's libmpv) without a name clash. Settings → Player engine picks it (restart).
# Usage: scripts/build-libmpv.sh <out-dir>     (Linux x64; other platforms follow in their own PRs)
# Normally run through scripts/build-libmpv-container.sh, which builds on Ubuntu 24.04 (glibc 2.39, the oldest
# system the Linux release supports) with every package it needs, whatever the host is.
# Output: <out-dir>/libgerdmpv.so and <out-dir>/libgerdmpv.txt (versions, sources and configure flags, shown on the
# Licences screen). Needs: meson ≥ 1.3, ninja, nasm, pkg-config, a C compiler, python3-jinja2, hwdata, and the -dev
# packages of the system libraries it links dynamically (libass, libva, libdrm, EGL/GL, PulseAudio, ALSA, GnuTLS,
# zlib): only libraries whose soname is stable across distributions.
# Debugging: every stage logs to <out-dir>/work/<stage>.log; a failed stage prints that log's tail. Sources are
# pinned by SHA-256 (tarballs) or commit (libplacebo, which needs its git submodules).
set -euo pipefail

FFMPEG_VERSION=9.1
FFMPEG_SHA256=1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433
MPV_VERSION=0.42.0
MPV_SHA256=bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd
LIBPLACEBO_TAG=v7.387.0
LIBPLACEBO_COMMIT=275f7dea27924cdd34ab2e6c20e448b6bc4fab65
LIBDISPLAY_INFO_VERSION=0.2.0
LIBDISPLAY_INFO_SHA256=5a2f002a16f42dd3540c8846f80a90b8f4bdcd067a94b9d2087bc2feae974176
GLIBC_MAX=2.39 # the release manifest's promise for Linux ("x64, glibc 2.39")

out="$(mkdir -p "$1" && cd "$1" && pwd)"
work="$out/work"
prefix="$work/prefix" # the static FFmpeg; nothing is installed system-wide
mkdir -p "$work"
jobs="$(nproc)"

stage() { # name, command…: runs quietly into work/<name>.log
  local name="$1"
  shift
  echo "build-libmpv: $name"
  if ! "$@" >"$work/$name.log" 2>&1; then
    tail -n 40 "$work/$name.log"
    echo "build-libmpv: $name failed (log: $work/$name.log)"
    exit 1
  fi
}

fetch() { # url, sha256, file
  [[ -f "$work/$3" ]] || curl -fsSL "$1" -o "$work/$3"
  echo "$2  $work/$3" | sha256sum -c --quiet
}

fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" ffmpeg.tar.xz
fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" "$MPV_SHA256" mpv.tar.gz
fetch "https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/$LIBDISPLAY_INFO_VERSION/downloads/libdisplay-info-$LIBDISPLAY_INFO_VERSION.tar.xz" \
  "$LIBDISPLAY_INFO_SHA256" libdisplay-info.tar.xz
rm -rf "$work/ffmpeg" "$work/mpv" "$work/libdisplay-info"
mkdir -p "$work/ffmpeg" "$work/mpv/subprojects" "$work/libdisplay-info"
tar -xJf "$work/ffmpeg.tar.xz" -C "$work/ffmpeg" --strip-components 1
tar -xzf "$work/mpv.tar.gz" -C "$work/mpv" --strip-components 1
tar -xJf "$work/libdisplay-info.tar.xz" -C "$work/libdisplay-info" --strip-components 1

# FFmpeg: static and position-independent, so it links into the one shared library. LGPL: no --enable-gpl and no
# --enable-nonfree. Autodetection is off, so only what is listed here is linked (and named on the Licences screen).
# Encoders: only what mpv's screenshots use; muxers stay (the recorder writes .ts/.mkv).
ffmpeg_flags=(
  --prefix="$prefix" --enable-static --disable-shared --enable-pic
  --disable-programs --disable-doc --disable-debug --disable-autodetect --disable-avdevice
  --disable-encoders --enable-encoder=png,mjpeg
  --enable-zlib --enable-gnutls --enable-vaapi --enable-libdrm --enable-pthreads
)
stage ffmpeg-configure bash -c "cd '$work/ffmpeg' && ./configure ${ffmpeg_flags[*]}"
stage ffmpeg-build make -C "$work/ffmpeg" -j"$jobs" install
# Static .pc files name their own dependencies under Libs.private, which a shared build ignores: fold them in.
python3 - "$prefix"/lib/pkgconfig/*.pc <<'EOF'
import re, sys
for p in sys.argv[1:]:
    s = open(p).read()
    priv = " ".join(re.findall(r"^Libs\.private: (.*)$", s, re.M))
    s = re.sub(r"^Libs\.private: .*\n", "", s, flags=re.M)
    s = re.sub(r"^(Libs: .*)$", lambda m: (m.group(1) + " " + priv).rstrip(), s, count=1, flags=re.M)
    open(p, "w").write(s)
EOF

# libplacebo (mpv ≥ 0.42 needs ≥ 7.387, newer than the distributions ship) as a meson subproject: mpv's meson.build
# asks for it static by default, so it ends up inside libgerdmpv.so too.
if [[ ! -d "$work/libplacebo" ]]; then
  stage libplacebo-fetch git clone -q --depth 1 --branch "$LIBPLACEBO_TAG" --recurse-submodules --shallow-submodules \
    https://code.videolan.org/videolan/libplacebo.git "$work/libplacebo"
fi
[[ "$(git -C "$work/libplacebo" rev-parse HEAD)" == "$LIBPLACEBO_COMMIT" ]] ||
  { echo "build-libmpv: libplacebo $LIBPLACEBO_TAG is not commit $LIBPLACEBO_COMMIT"; exit 1; }
ln -sfn "$work/libplacebo" "$work/mpv/subprojects/libplacebo"
# libdisplay-info (mpv's DRM support needs it) is linked in statically too: its soname changes between
# distributions (.so.1, .so.2, .so.3), so a dynamic link would tie the library to one of them.
ln -sfn "$work/libdisplay-info" "$work/mpv/subprojects/libdisplay-info"

# mpv: only libmpv (no CLI), LGPL, every optional feature off unless listed (what media_kit's video output and an
# IPTV player use: OpenGL/EGL rendering, VA-API decoding through the DRM render node, PulseAudio/ALSA, subtitles
# via libass). VA-API needs a display backend: X11 is GPL-only in mpv, and Ubuntu 24.04's Wayland is older than
# mpv 0.42 accepts, so DRM it is, on X11 and Wayland desktops alike (copy mode, not zero-copy).
mpv_flags=(
  --buildtype=release --default-library=shared --auto-features=disabled
  --force-fallback-for=libplacebo,libdisplay-info -Dlibdisplay-info:default_library=static
  -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dtests=false
  -Dlibplacebo:demos=false -Dlibplacebo:vulkan=disabled -Dlibplacebo:opengl=enabled
  -Dgl=enabled -Degl=enabled -Dplain-gl=enabled -Dvaapi=enabled -Ddrm=enabled
  -Dvaapi-drm=enabled
  -Dpulse=enabled -Dalsa=enabled -Diconv=enabled -Dzlib=enabled
)
stage mpv-configure env PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson setup "$work/mpv-build" "$work/mpv" "${mpv_flags[@]}"
stage mpv-build ninja -C "$work/mpv-build"

# The library under its own name (file and soname), so nothing can mistake it for the system's libmpv.so.2.
lib="$(find "$work/mpv-build" -maxdepth 1 -type f -name 'libmpv.so.*.*' | head -n 1)"
[[ -n "$lib" ]] || { echo "build-libmpv: no libmpv.so in $work/mpv-build"; exit 1; }
cp "$lib" "$out/libgerdmpv.so"
stage soname patchelf --set-soname libgerdmpv.so "$out/libgerdmpv.so"
# It must not need the system's FFmpeg or libmpv at run time.
if ldd "$out/libgerdmpv.so" | grep -E 'libav(codec|format|util|filter)|libsw(scale|resample)|libmpv|libplacebo|libdisplay-info'; then
  echo "build-libmpv: libgerdmpv.so still links one of the above dynamically"
  exit 1
fi
# And it must load on the oldest supported system (a newer build host would raise this unnoticed).
glibc="$(objdump -T "$out/libgerdmpv.so" | grep -o 'GLIBC_2\.[0-9]*' | sort -t. -k2 -n -u | tail -n 1)"
if [[ "$(printf '%s\n' "GLIBC_$GLIBC_MAX" "$glibc" | sort -t. -k2 -n | tail -n 1)" != "GLIBC_$GLIBC_MAX" ]]; then
  echo "build-libmpv: libgerdmpv.so needs $glibc, newer than glibc $GLIBC_MAX (build it in the container)"
  exit 1
fi

cat >"$out/libgerdmpv.txt" <<EOF
gerdTV's own libmpv (libgerdmpv.so), LGPL build.
mpv $MPV_VERSION (LGPL-2.1+ with -Dgpl=false): https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz
FFmpeg $FFMPEG_VERSION (LGPL-2.1+): https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
libplacebo $LIBPLACEBO_TAG (LGPL-2.1+): https://code.videolan.org/videolan/libplacebo (commit $LIBPLACEBO_COMMIT)
libdisplay-info $LIBDISPLAY_INFO_VERSION (MIT): https://gitlab.freedesktop.org/emersion/libdisplay-info
FFmpeg configure: ${ffmpeg_flags[*]/--prefix=*/}
mpv meson: ${mpv_flags[*]}
EOF
echo "build-libmpv: $out/libgerdmpv.so ($(du -h "$out/libgerdmpv.so" | cut -f1))"
