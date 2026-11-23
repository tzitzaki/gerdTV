#!/bin/sh
# Xcode build phase (app/macos and app/ios Runner targets, after Flutter's own embed step): copies gerdTV's own libmpv
# (build/libmpv-apple/GerdMpv.xcframework, scripts/build-libmpv-apple.sh) into the app's Frameworks folder and signs
# it like Flutter signs its frameworks, without linking it: it is only loaded when Settings → Player engine picks it
# (app/lib/platform/engine.dart). Does nothing when it hasn't been built.
# Debugging: the build log shows "embed-libmpv-apple: …"; the slice comes from Xcode's PLATFORM_NAME.
set -eu
xcf="$SRCROOT/../../build/libmpv-apple/GerdMpv.xcframework"
[ -d "$xcf" ] || { echo "embed-libmpv-apple: no GerdMpv.xcframework (only media_kit's engine)"; exit 0; }
case "$PLATFORM_NAME" in
  macosx) slice=macos-arm64_x86_64 ;;
  iphoneos) slice=ios-arm64 ;;
  iphonesimulator) slice=ios-arm64-simulator ;;
  *) echo "embed-libmpv-apple: no slice for $PLATFORM_NAME"; exit 0 ;;
esac
dest="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$dest"
rm -rf "$dest/GerdMpv.framework"
cp -R "$xcf/$slice/GerdMpv.framework" "$dest/"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$dest/GerdMpv.framework"
fi
echo "embed-libmpv-apple: GerdMpv.framework ($slice) → $dest"
