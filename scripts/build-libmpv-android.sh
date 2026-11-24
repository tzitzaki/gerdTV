#!/usr/bin/env bash
# gerdTV's own libmpv for Android (owner decision, docs/DECISIONS.md): the same mpv, FFmpeg and libplacebo as Linux
# (scripts/build-libmpv.sh), cross-built with the NDK into ONE self-contained shared library per ABI, libgerdmpv.so,
# LGPL configuration. Everything it needs beyond Android's own system libraries (libc, liblog, libandroid,
# libmediandk, libEGL, libGLESv3, libOpenSLES/AAudio) is linked in statically: mbedTLS (https), FreeType, FriBidi,
# HarfBuzz and libass (subtitles; mpv requires libass), and the C++ runtime (libplacebo and HarfBuzz are C++), so
# it can't clash with the libc++_shared.so media_kit's engine brings.
# Usage: scripts/build-libmpv-android.sh <out-dir> <abi>      abi: arm64-v8a (phones, the Shield) or x86_64 (emulator)
# Needs: the NDK (ANDROID_NDK_HOME, or the newest under ~/sdk/android/ndk), meson ≥ 1.3, ninja, cmake, nasm,
# pkg-config, python3-jinja2, curl, git. Output: <out-dir>/<abi>/libgerdmpv.so and <out-dir>/libgerdmpv-android.txt
# (versions and flags for the Licences screen). Hardware decoding: MediaCodec through FFmpeg's JNI support; the app
# hands the JavaVM to the library before media_kit starts (av_jni_set_java_vm, app/lib/platform/engine.dart).
# Debugging: every stage logs to <out-dir>/work-<abi>/<stage>.log; a failed stage prints that log's tail.
set -euo pipefail

# The Linux build's pins (keep them equal: one engine, one set of versions).
FFMPEG_VERSION=9.1
FFMPEG_SHA256=1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433
MPV_VERSION=0.42.0
MPV_SHA256=bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd
LIBPLACEBO_TAG=v7.387.0
LIBPLACEBO_COMMIT=275f7dea27924cdd34ab2e6c20e448b6bc4fab65
# Android only (static; the SHA-256 of mbedTLS is the project's own published sum).
MBEDTLS_VERSION=3.6.8 # LTS; FFmpeg 9.1 supports 3.x
MBEDTLS_SHA256=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b
FREETYPE_VERSION=2.14.3
FREETYPE_SHA256=36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
FRIBIDI_VERSION=1.0.18
FRIBIDI_SHA256=1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f
HARFBUZZ_VERSION=15.2.0
HARFBUZZ_SHA256=e2ec49090744383cdbe7df808c1cedaafba06a97be8dc4211fe546ba585f12cb
LIBASS_VERSION=0.17.5
LIBASS_SHA256=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
API=24 # Flutter's minSdk

out="$(mkdir -p "$1" && cd "$1" && pwd)"
abi="$2"
case "$abi" in
  arm64-v8a) triple=aarch64-linux-android cpu_family=aarch64 cpu=armv8-a ffarch=aarch64 ;;
  x86_64) triple=x86_64-linux-android cpu_family=x86_64 cpu=x86_64 ffarch=x86_64 ;;
  *) echo "build-libmpv-android: unknown ABI $abi (arm64-v8a or x86_64)"; exit 1 ;;
esac
ndk="${ANDROID_NDK_HOME:-$(ls -d "$HOME"/sdk/android/ndk/* | sort -V | tail -n 1)}"
toolchain="$ndk/toolchains/llvm/prebuilt/linux-x86_64"
[[ -x "$toolchain/bin/clang" ]] || { echo "build-libmpv-android: no NDK toolchain in $ndk"; exit 1; }
cc="$toolchain/bin/$triple$API-clang"
cxx="$toolchain/bin/$triple$API-clang++"
work="$out/work-$abi"
prefix="$work/prefix" # every static dependency; nothing is installed system-wide
mkdir -p "$work" "$prefix" "$out/$abi"
jobs="$(nproc)"

stage() { # name, command…: runs quietly into work/<name>.log
  local name="$1"
  shift
  echo "build-libmpv-android [$abi]: $name"
  if ! "$@" >"$work/$name.log" 2>&1; then
    tail -n 40 "$work/$name.log"
    echo "build-libmpv-android: $name failed (log: $work/$name.log)"
    exit 1
  fi
}

fetch() { # url, sha256, file (downloads are shared between ABIs)
  mkdir -p "$out/dl"
  [[ -f "$out/dl/$3" ]] || curl -fsSL "$1" -o "$out/dl/$3"
  echo "$2  $out/dl/$3" | sha256sum -c --quiet
}

unpack() { # file, dir
  rm -rf "$work/$2"
  mkdir -p "$work/$2"
  tar -xf "$out/dl/$1" -C "$work/$2" --strip-components 1
}

fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" ffmpeg.tar.xz
fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" "$MPV_SHA256" mpv.tar.gz
fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2" \
  "$MBEDTLS_SHA256" mbedtls.tar.bz2
fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz" "$FREETYPE_SHA256" \
  freetype.tar.xz
fetch "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz" \
  "$FRIBIDI_SHA256" fribidi.tar.xz
fetch "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz" \
  "$HARFBUZZ_SHA256" harfbuzz.tar.xz
fetch "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz" \
  "$LIBASS_SHA256" libass.tar.xz
for p in ffmpeg mpv mbedtls freetype fribidi harfbuzz libass; do
  unpack "$(cd "$out/dl" && ls $p.tar.*)" "$p"
done

# One meson cross file for every meson project: the NDK's clang for this ABI and API level, static C++ runtime.
cross="$work/cross.ini"
cat >"$cross" <<EOF
[binaries]
c = '$cc'
cpp = '$cxx'
ar = '$toolchain/bin/llvm-ar'
strip = '$toolchain/bin/llvm-strip'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-fPIC']
cpp_args = ['-fPIC']
cpp_link_args = ['-static-libstdc++']
[properties]
pkg_config_libdir = '$prefix/lib/pkgconfig'
[host_machine]
system = 'android'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'
EOF
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=""
meson_static=(--cross-file "$cross" --prefix "$prefix" --libdir lib --buildtype=release --default-library=static)

# mbedTLS: CMake with the NDK's toolchain file; library only.
stage mbedtls-configure cmake -S "$work/mbedtls" -B "$work/mbedtls-build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" -DANDROID_ABI="$abi" -DANDROID_PLATFORM="$API" \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
stage mbedtls-build cmake --build "$work/mbedtls-build" --target install
# (mbedTLS 3.6 installs no .pc files for FFmpeg's configure: FFmpeg finds it by headers and -l flags.)

# Text rendering for subtitles: FreeType (no PNG, bzip2, brotli, HarfBuzz loop), FriBidi, HarfBuzz (FreeType only),
# libass (no system font provider: Android has no fontconfig; embedded fonts of a subtitle stream still work).
stage freetype meson setup "$work/freetype-build" "$work/freetype" "${meson_static[@]}" \
  -Dzlib=disabled -Dbzip2=disabled -Dpng=disabled -Dbrotli=disabled -Dharfbuzz=disabled -Dtests=disabled
stage freetype-build ninja -C "$work/freetype-build" install
stage fribidi meson setup "$work/fribidi-build" "$work/fribidi" "${meson_static[@]}" \
  -Ddocs=false -Dbin=false -Dtests=false
stage fribidi-build ninja -C "$work/fribidi-build" install
stage harfbuzz meson setup "$work/harfbuzz-build" "$work/harfbuzz" "${meson_static[@]}" \
  -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dicu=disabled \
  -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled
stage harfbuzz-build ninja -C "$work/harfbuzz-build" install
stage libass meson setup "$work/libass-build" "$work/libass" "${meson_static[@]}" \
  -Dfontconfig=disabled -Drequire-system-font-provider=false -Dtest=disabled -Dcompare=disabled \
  -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled -Dlibunibreak=disabled
stage libass-build ninja -C "$work/libass-build" install

# FFmpeg: static and position-independent, LGPL (no --enable-gpl, no --enable-nonfree; version3 because mbedTLS is
# Apache-2.0, which makes this FFmpeg LGPL-3.0+, still GPL-3.0 compatible), autodetection off, so only what is listed
# is linked: MediaCodec decoding (JNI), mbedTLS for https, the NDK's zlib.
ffmpeg_flags=(
  --prefix="$prefix" --enable-static --disable-shared --enable-pic
  --enable-cross-compile --target-os=android --arch="$ffarch" --cc="$cc" --cxx="$cxx"
  --ar="$toolchain/bin/llvm-ar" --ranlib="$toolchain/bin/llvm-ranlib" --nm="$toolchain/bin/llvm-nm"
  --strip="$toolchain/bin/llvm-strip"
  --disable-programs --disable-doc --disable-debug --disable-autodetect --disable-avdevice
  --disable-encoders --enable-encoder=png,mjpeg
  --enable-version3 --enable-jni --enable-mediacodec --enable-mbedtls --enable-zlib --enable-pthreads
  --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib"
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

# libplacebo as mpv's meson subproject (static, like on Linux).
mkdir -p "$work/mpv/subprojects"
if [[ ! -d "$out/dl/libplacebo" ]]; then
  stage libplacebo-fetch git clone -q --depth 1 --branch "$LIBPLACEBO_TAG" --recurse-submodules --shallow-submodules \
    https://code.videolan.org/videolan/libplacebo.git "$out/dl/libplacebo"
fi
[[ "$(git -C "$out/dl/libplacebo" rev-parse HEAD)" == "$LIBPLACEBO_COMMIT" ]] ||
  { echo "build-libmpv-android: libplacebo $LIBPLACEBO_TAG is not commit $LIBPLACEBO_COMMIT"; exit 1; }
ln -sfn "$out/dl/libplacebo" "$work/mpv/subprojects/libplacebo"

# mpv: only libmpv, LGPL, every optional feature off unless listed: OpenGL ES through EGL (media_kit renders into
# an Android surface), MediaCodec decoding, AudioTrack and AAudio output, libass subtitles.
mpv_flags=(
  --cross-file "$cross" --buildtype=release --default-library=shared --auto-features=disabled
  --force-fallback-for=libplacebo
  -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dtests=false
  -Dlibplacebo:demos=false -Dlibplacebo:vulkan=disabled -Dlibplacebo:opengl=enabled
  -Dgl=enabled -Degl-android=enabled -Dandroid-media-ndk=enabled
  -Daudiotrack=enabled -Daaudio=enabled -Diconv=disabled -Dzlib=enabled
  -Dcpp_link_args=-static-libstdc++
)
stage mpv-configure meson setup "$work/mpv-build" "$work/mpv" "${mpv_flags[@]}"
stage mpv-build ninja -C "$work/mpv-build"

# The library under its own name: Android loads libraries by file name, and media_kit's engine is libmpv.so.
lib="$work/mpv-build/libmpv.so"
[[ -f "$lib" ]] || { echo "build-libmpv-android: no libmpv.so in $work/mpv-build"; exit 1; }
"$toolchain/bin/llvm-objcopy" --strip-unneeded "$lib" "$out/$abi/libgerdmpv.so"
stage soname patchelf --set-soname libgerdmpv.so "$out/$abi/libgerdmpv.so"
# It may only need Android's system libraries (no FFmpeg, libmpv, libc++_shared of anyone else's), and it must
# export the JNI hook the app calls.
needed="$("$toolchain/bin/llvm-readelf" -d "$out/$abi/libgerdmpv.so" | grep NEEDED | grep -o '\[.*\]' | tr -d '[]')"
for n in $needed; do
  case "$n" in
    libc.so | libm.so | libdl.so | liblog.so | libandroid.so | libmediandk.so | libEGL.so | libGLESv2.so | \
      libGLESv3.so | libOpenSLES.so | libaaudio.so | libz.so) ;;
    *) echo "build-libmpv-android: libgerdmpv.so needs $n (only Android's own libraries are allowed)"; exit 1 ;;
  esac
done
# (Into a variable first: grep -q would stop reading early, and pipefail turns nm's broken pipe into a failure.)
exports="$("$toolchain/bin/llvm-nm" -D --defined-only "$out/$abi/libgerdmpv.so")"
grep -qw av_jni_set_java_vm <<<"$exports" ||
  { echo "build-libmpv-android: av_jni_set_java_vm is not exported (MediaCodec would fail)"; exit 1; }

cat >"$out/libgerdmpv-android.txt" <<EOF
gerdTV's own libmpv for Android (libgerdmpv.so, arm64-v8a and x86_64), LGPL build.
mpv $MPV_VERSION (LGPL-2.1+ with -Dgpl=false), FFmpeg $FFMPEG_VERSION (LGPL-3.0+: version3 for mbedTLS), libplacebo $LIBPLACEBO_TAG (LGPL-2.1+)
mbedTLS $MBEDTLS_VERSION (Apache-2.0), FreeType $FREETYPE_VERSION (FTL), FriBidi $FRIBIDI_VERSION (LGPL-2.1+),
HarfBuzz $HARFBUZZ_VERSION (MIT), libass $LIBASS_VERSION (ISC)
FFmpeg configure: ${ffmpeg_flags[*]/--prefix=*/}
mpv meson: ${mpv_flags[*]}
EOF
echo "build-libmpv-android: $out/$abi/libgerdmpv.so ($(du -h "$out/$abi/libgerdmpv.so" | cut -f1))"
