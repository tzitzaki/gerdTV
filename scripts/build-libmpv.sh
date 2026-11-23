#!/usr/bin/env bash
# gerdTV's own libmpv (owner decision, docs/DECISIONS.md): current mpv with FFmpeg and libplacebo linked in, LGPL
# configuration, as ONE self-contained shared library named libgerdmpv.so, so it can sit next to the engine media_kit
# bundles (or the system's libmpv) without a name clash. Settings → Player engine picks it (restart).
# Usage: scripts/build-libmpv.sh <out-dir>     (Linux x64; other platforms follow in their own PRs)
# Output: <out-dir>/libgerdmpv.so and <out-dir>/libgerdmpv.txt (versions, sources and configure flags, shown on the
# Licences screen). Needs: meson ≥ 1.3, ninja, nasm, pkg-config, a C compiler, python3-jinja2, and the -dev packages
# of the system libraries it links dynamically (libass, libva, libdrm, EGL/GL, Wayland, PulseAudio, ALSA, GnuTLS,
# zlib).
# Debugging: every stage logs to <out-dir>/work/<stage>.log; a failed stage prints that log's tail. Sources are
# pinned by SHA-256 (tarballs) or commit (libplacebo, which needs its git submodules).
set -euo pipefail

FFMPEG_VERSION=9.1
FFMPEG_SHA256=1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433
MPV_VERSION=0.42.0
MPV_SHA256=bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd
LIBPLACEBO_TAG=v7.387.0
LIBPLACEBO_COMMIT=275f7dea27924cdd34ab2e6c20e448b6bc4fab65

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
rm -rf "$work/ffmpeg" "$work/mpv" && mkdir -p "$work/ffmpeg" "$work/mpv"
tar -xJf "$work/ffmpeg.tar.xz" -C "$work/ffmpeg" --strip-components 1
tar -xzf "$work/mpv.tar.gz" -C "$work/mpv" --strip-components 1

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
mkdir -p "$work/mpv/subprojects"
ln -sfn "$work/libplacebo" "$work/mpv/subprojects/libplacebo"

# mpv: only libmpv (no CLI), LGPL, every optional feature off unless listed (what media_kit's video output and an
# IPTV player use: OpenGL/EGL rendering, VA-API decoding on Wayland and DRM, PulseAudio/ALSA, subtitles via
# libass). VA-API needs at least one display backend, or meson refuses it. mpv's X11 backend is GPL-only, so an
# X11 session decodes with VA-API through the DRM render node (copy mode) instead of zero-copy.
mpv_flags=(
  --buildtype=release --default-library=shared --auto-features=disabled --force-fallback-for=libplacebo
  -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dtests=false
  -Dlibplacebo:demos=false -Dlibplacebo:vulkan=disabled -Dlibplacebo:opengl=enabled
  -Dgl=enabled -Degl=enabled -Dplain-gl=enabled -Dvaapi=enabled -Ddrm=enabled
  -Dwayland=enabled -Degl-wayland=enabled -Degl-drm=enabled -Dvaapi-wayland=enabled -Dvaapi-drm=enabled
  -Dpulse=enabled -Dalsa=enabled -Diconv=enabled -Dzlib=enabled
)
stage mpv-configure env PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson setup "$work/mpv-build" "$work/mpv" "${mpv_flags[@]}"
stage mpv-build ninja -C "$work/mpv-build"

# The library under its own name (file and soname), so nothing can mistake it for the system's libmpv.so.2.
lib="$(find "$work/mpv-build" -maxdepth 1 -name 'libmpv.so.*.*' | head -n 1)"
[[ -n "$lib" ]] || { echo "build-libmpv: no libmpv.so in $work/mpv-build"; exit 1; }
cp "$lib" "$out/libgerdmpv.so"
stage soname patchelf --set-soname libgerdmpv.so "$out/libgerdmpv.so"
# It must not need the system's FFmpeg or libmpv at run time.
if ldd "$out/libgerdmpv.so" | grep -E 'libav(codec|format|util|filter)|libsw(scale|resample)|libmpv|libplacebo'; then
  echo "build-libmpv: libgerdmpv.so still links one of the above dynamically"
  exit 1
fi

cat >"$out/libgerdmpv.txt" <<EOF
gerdTV's own libmpv (libgerdmpv.so), LGPL build.
mpv $MPV_VERSION (LGPL-2.1+ with -Dgpl=false): https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz
FFmpeg $FFMPEG_VERSION (LGPL-2.1+): https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
libplacebo $LIBPLACEBO_TAG (LGPL-2.1+): https://code.videolan.org/videolan/libplacebo (commit $LIBPLACEBO_COMMIT)
FFmpeg configure: ${ffmpeg_flags[*]/--prefix=*/}
mpv meson: ${mpv_flags[*]}
EOF
echo "build-libmpv: $out/libgerdmpv.so ($(du -h "$out/libgerdmpv.so" | cut -f1))"
