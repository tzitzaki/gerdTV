#!/usr/bin/env bash
# gerdTV's own libmpv for macOS and iOS (owner decision, docs/DECISIONS.md): the Linux pins (scripts/build-libmpv.sh)
# built for every Apple slice the app ships, each as ONE dynamic library with FFmpeg, libplacebo and the subtitle
# stack (FreeType, FriBidi, HarfBuzz, libass) linked in statically, LGPL configuration, packed as
# GerdMpv.xcframework (macOS universal arm64 + x86_64, iOS arm64, iOS simulator arm64). It only needs Apple's system
# frameworks; TLS comes from Apple's Secure Transport, decoding from VideoToolbox.
# The app embeds it next to media_kit's Mpv.xcframework (scripts/bundle-libmpv-apple.sh) and loads one of the two
# at start (Settings → Player engine, app/lib/platform/engine.dart); the vendored media_kit_video plugin finds the
# loaded one's functions at run time (third_party/README.md).
# Usage: scripts/build-libmpv-apple.sh <out-dir>     (macOS with Xcode; needs meson, ninja, pkg-config, cmake, python3
# with jinja2 — the CI job installs them). Output: <out-dir>/GerdMpv.xcframework and <out-dir>/libgerdmpv-apple.txt.
# Debugging: every stage logs to <out-dir>/work-<slice>/<stage>.log; a failed stage prints that log's tail.
set -euo pipefail

# The Linux build's pins (keep them equal: one engine, one set of versions).
FFMPEG_VERSION=9.1
FFMPEG_SHA256=1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433
MPV_VERSION=0.42.0
MPV_SHA256=bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd
LIBPLACEBO_TAG=v7.387.0
LIBPLACEBO_COMMIT=275f7dea27924cdd34ab2e6c20e448b6bc4fab65
# The Android build's subtitle stack (scripts/build-libmpv-android.sh).
FREETYPE_VERSION=2.14.3
FREETYPE_SHA256=36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
FRIBIDI_VERSION=1.0.18
FRIBIDI_SHA256=1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f
HARFBUZZ_VERSION=15.2.0
HARFBUZZ_SHA256=e2ec49090744383cdbe7df808c1cedaafba06a97be8dc4211fe546ba585f12cb
LIBASS_VERSION=0.17.5
LIBASS_SHA256=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
MACOS_MIN=12.0 # the release manifest's minimum (release.yml)
IOS_MIN=15.0

out="$(mkdir -p "$1" && cd "$1" && pwd)"
jobs="$(sysctl -n hw.ncpu)"

fetch() { # url, sha256, file (shared by every slice)
  mkdir -p "$out/dl"
  [[ -f "$out/dl/$3" ]] || curl -fsSL "$1" -o "$out/dl/$3"
  echo "$2  $out/dl/$3" | shasum -a 256 -c --quiet
}
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" ffmpeg.tar.xz
fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" "$MPV_SHA256" mpv.tar.gz
fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz" "$FREETYPE_SHA256" \
  freetype.tar.xz
fetch "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz" \
  "$FRIBIDI_SHA256" fribidi.tar.xz
fetch "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz" \
  "$HARFBUZZ_SHA256" harfbuzz.tar.xz
fetch "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz" \
  "$LIBASS_SHA256" libass.tar.xz
if [[ ! -d "$out/dl/libplacebo" ]]; then
  git clone -q --depth 1 --branch "$LIBPLACEBO_TAG" --recurse-submodules --shallow-submodules \
    https://code.videolan.org/videolan/libplacebo.git "$out/dl/libplacebo"
fi
[[ "$(git -C "$out/dl/libplacebo" rev-parse HEAD)" == "$LIBPLACEBO_COMMIT" ]] ||
  { echo "build-libmpv-apple: libplacebo $LIBPLACEBO_TAG is not commit $LIBPLACEBO_COMMIT"; exit 1; }

# One slice: <name> <sdk> <arch> <clang target> <meson system cpu_family>
build_slice() {
  local name="$1" sdk="$2" arch="$3" target="$4" cpu_family="$5"
  local work="$out/work-$name" prefix="$out/work-$name/prefix"
  local sysroot cc
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  mkdir -p "$work" "$prefix"
  stage() { # name, command…: runs quietly into work/<name>.log
    local s="$1"
    shift
    echo "build-libmpv-apple [$name]: $s"
    if ! "$@" >"$work/$s.log" 2>&1; then
      tail -n 40 "$work/$s.log"
      echo "build-libmpv-apple: $s failed (log: $work/$s.log)"
      exit 1
    fi
  }
  for p in ffmpeg mpv freetype fribidi harfbuzz libass; do
    rm -rf "${work:?}/$p" && mkdir -p "$work/$p"
    tar -xf "$out/dl/$(cd "$out/dl" && ls $p.tar.*)" -C "$work/$p" --strip-components 1
  done
  local flags="-target $target -isysroot $sysroot"
  cat >"$work/cross.ini" <<EOF
[binaries]
c = ['$cc', '-target', '$target', '-isysroot', '$sysroot']
cpp = ['$(xcrun --sdk "$sdk" -f clang++)', '-target', '$target', '-isysroot', '$sysroot']
objc = ['$cc', '-target', '$target', '-isysroot', '$sysroot']
objcpp = ['$(xcrun --sdk "$sdk" -f clang++)', '-target', '$target', '-isysroot', '$sysroot']
ar = '$(xcrun --sdk "$sdk" -f ar)'
strip = '$(xcrun --sdk "$sdk" -f strip)'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-fPIC']
cpp_args = ['-fPIC']
[properties]
pkg_config_libdir = '$prefix/lib/pkgconfig'
[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
EOF
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=""
  local static=(--cross-file "$work/cross.ini" --prefix "$prefix" --libdir lib --buildtype=release
    --default-library=static)

  # Subtitles: FreeType, FriBidi, HarfBuzz (FreeType only, no CoreText shaper), libass (fonts through CoreText).
  stage freetype meson setup "$work/freetype-build" "$work/freetype" "${static[@]}" \
    -Dzlib=disabled -Dbzip2=disabled -Dpng=disabled -Dbrotli=disabled -Dharfbuzz=disabled -Dtests=disabled
  stage freetype-build ninja -C "$work/freetype-build" install
  stage fribidi meson setup "$work/fribidi-build" "$work/fribidi" "${static[@]}" -Ddocs=false -Dbin=false -Dtests=false
  stage fribidi-build ninja -C "$work/fribidi-build" install
  stage harfbuzz meson setup "$work/harfbuzz-build" "$work/harfbuzz" "${static[@]}" \
    -Dfreetype=enabled -Dcoretext=disabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
    -Dicu=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled
  stage harfbuzz-build ninja -C "$work/harfbuzz-build" install
  stage libass meson setup "$work/libass-build" "$work/libass" "${static[@]}" \
    -Dfontconfig=disabled -Dcoretext=enabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled \
    -Dcheckasm=disabled -Dlibunibreak=disabled -Dasm=disabled
  stage libass-build ninja -C "$work/libass-build" install

  # FFmpeg: static, LGPL (no --enable-gpl, no --enable-nonfree), autodetection off: VideoToolbox decoding, Secure
  # Transport for https, the SDK's zlib. No x86 assembly (it would need nasm; Intel Macs decode in hardware anyway).
  local ffmpeg_flags=(
    --prefix="$prefix" --enable-static --disable-shared --enable-pic
    --enable-cross-compile --target-os=darwin --arch="$arch" --cc="$cc" --sysroot="$sysroot"
    --extra-cflags="$flags" --extra-ldflags="$flags" --disable-x86asm
    --disable-programs --disable-doc --disable-debug --disable-autodetect --disable-avdevice
    --disable-encoders --enable-encoder=png,mjpeg
    --enable-videotoolbox --enable-securetransport --enable-zlib --enable-pthreads
  )
  stage ffmpeg-configure bash -c "cd '$work/ffmpeg' && ./configure $(printf "'%s' " "${ffmpeg_flags[@]}")"
  stage ffmpeg-build make -C "$work/ffmpeg" -j"$jobs" install
  python3 - "$prefix"/lib/pkgconfig/*.pc <<'EOF'
import re, sys
for p in sys.argv[1:]:
    s = open(p).read()
    priv = " ".join(re.findall(r"^Libs\.private: (.*)$", s, re.M))
    s = re.sub(r"^Libs\.private: .*\n", "", s, flags=re.M)
    s = re.sub(r"^(Libs: .*)$", lambda m: (m.group(1) + " " + priv).rstrip(), s, count=1, flags=re.M)
    open(p, "w").write(s)
EOF

  # mpv: only libmpv, LGPL, every optional feature off unless listed: OpenGL for media_kit's render API (macOS: CGL,
  # iOS: OpenGL ES), VideoToolbox interop, CoreAudio (macOS) or AudioUnit (iOS), libass subtitles.
  mkdir -p "$work/mpv/subprojects"
  ln -sfn "$out/dl/libplacebo" "$work/mpv/subprojects/libplacebo"
  local mpv_flags=(
    --cross-file "$work/cross.ini" --buildtype=release --default-library=shared --auto-features=disabled
    --force-fallback-for=libplacebo
    -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dtests=false
    -Dlibplacebo:demos=false -Dlibplacebo:vulkan=disabled -Dlibplacebo:opengl=enabled
    -Dgl=enabled -Dplain-gl=enabled -Dzlib=enabled -Diconv=enabled
  )
  if [[ "$sdk" == macosx ]]; then
    # mpv's Cocoa layer (needed by gl-cocoa, whose VideoToolbox interop keeps decoding in hardware) is partly Swift;
    # swiftc gets the slice's target like clang (the Swift runtime is part of macOS 12), and libplacebo's generated
    # config.h, which mpv's Swift rule doesn't pass (it only names libplacebo's source include folder).
    mpv_flags+=(-Dcocoa=enabled -Dswift-build=enabled
      "-Dswift-flags=-target $target -I$work/mpv-build/subprojects/libplacebo/src/include" -Dcoreaudio=enabled
      -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled)
  else
    mpv_flags+=(-Dswift-build=disabled -Daudiounit=enabled -Dios-gl=enabled)
  fi
  stage mpv-configure meson setup "$work/mpv-build" "$work/mpv" "${mpv_flags[@]}"
  stage mpv-build ninja -C "$work/mpv-build"
  local lib
  lib="$(find "$work/mpv-build" -maxdepth 1 -type f -name 'libmpv.*.dylib' | head -n 1)"
  [[ -n "$lib" ]] || { echo "build-libmpv-apple: no libmpv dylib in $work/mpv-build"; exit 1; }
  cp "$lib" "$work/GerdMpv"
  # Only system libraries and frameworks (/usr/lib, /System): nothing from the build machine.
  if otool -L "$work/GerdMpv" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/|@rpath/libmpv)'; then
    echo "build-libmpv-apple: GerdMpv ($name) links the libraries above"
    exit 1
  fi
  printf '%s\n' "FFmpeg configure ($name): ${ffmpeg_flags[*]/--prefix=*/}" "mpv meson ($name): ${mpv_flags[*]}" \
    >"$work/flags.txt"
}

build_slice macos-arm64 macosx arm64 "arm64-apple-macos$MACOS_MIN" aarch64
build_slice macos-x86_64 macosx x86_64 "x86_64-apple-macos$MACOS_MIN" x86_64
build_slice ios-arm64 iphoneos arm64 "arm64-apple-ios$IOS_MIN" aarch64
build_slice iossim-arm64 iphonesimulator arm64 "arm64-apple-ios$IOS_MIN-simulator" aarch64

# Frameworks under their own name: macOS needs the versioned layout (Versions/A, symlinks), iOS the flat one.
plist() { # platform, minimum OS key/value
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>GerdMpv</string>
  <key>CFBundleIdentifier</key><string>world.zakis.gerdmpv</string>
  <key>CFBundleName</key><string>GerdMpv</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$MPV_VERSION</string>
  <key>CFBundleVersion</key><string>$MPV_VERSION</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$1</string></array>
  <key>$2</key><string>$3</string>
</dict></plist>
EOF
}
fw="$out/frameworks"
rm -rf "$fw" "$out/GerdMpv.xcframework"
mkdir -p "$fw/macos/GerdMpv.framework/Versions/A/Resources"
lipo -create "$out/work-macos-arm64/GerdMpv" "$out/work-macos-x86_64/GerdMpv" \
  -output "$fw/macos/GerdMpv.framework/Versions/A/GerdMpv"
install_name_tool -id @rpath/GerdMpv.framework/Versions/A/GerdMpv "$fw/macos/GerdMpv.framework/Versions/A/GerdMpv"
plist MacOSX LSMinimumSystemVersion "$MACOS_MIN" >"$fw/macos/GerdMpv.framework/Versions/A/Resources/Info.plist"
ln -s A "$fw/macos/GerdMpv.framework/Versions/Current"
ln -s Versions/Current/GerdMpv "$fw/macos/GerdMpv.framework/GerdMpv"
ln -s Versions/Current/Resources "$fw/macos/GerdMpv.framework/Resources"
for slice in ios-arm64:iPhoneOS iossim-arm64:iPhoneSimulator; do
  name="${slice%%:*}"
  mkdir -p "$fw/$name/GerdMpv.framework"
  cp "$out/work-$name/GerdMpv" "$fw/$name/GerdMpv.framework/GerdMpv"
  install_name_tool -id @rpath/GerdMpv.framework/GerdMpv "$fw/$name/GerdMpv.framework/GerdMpv"
  plist "${slice##*:}" MinimumOSVersion "$IOS_MIN" >"$fw/$name/GerdMpv.framework/Info.plist"
done
xcodebuild -create-xcframework -output "$out/GerdMpv.xcframework" \
  -framework "$fw/macos/GerdMpv.framework" -framework "$fw/ios-arm64/GerdMpv.framework" \
  -framework "$fw/iossim-arm64/GerdMpv.framework" >/dev/null

{
  echo "gerdTV's own libmpv for macOS and iOS (GerdMpv.xcframework), LGPL build."
  echo "mpv $MPV_VERSION (LGPL-2.1+ with -Dgpl=false), FFmpeg $FFMPEG_VERSION (LGPL-2.1+), libplacebo $LIBPLACEBO_TAG (LGPL-2.1+)"
  echo "FreeType $FREETYPE_VERSION (FTL), FriBidi $FRIBIDI_VERSION (LGPL-2.1+), HarfBuzz $HARFBUZZ_VERSION (MIT), libass $LIBASS_VERSION (ISC)"
  cat "$out"/work-*/flags.txt
} >"$out/libgerdmpv-apple.txt"
echo "build-libmpv-apple: $out/GerdMpv.xcframework ($(du -sh "$out/GerdMpv.xcframework" | cut -f1))"
