#!/usr/bin/env bash
# The macOS first-install image (owner decision): a DMG whose window holds gerdTV.app and a link to Applications,
# so installing is one drag. The updater keeps using the zip (latest.json), which it can unpack without mounting.
# Usage (on macOS): scripts/macos-dmg.sh <path/to/gerdTV.app> <out.dmg>
# Debug: "hdiutil: create failed" usually means the output already exists in use or the disk is full.
set -euo pipefail
app="$1"
out="$2"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/gerdTV.app"   # ditto keeps the bundle's symlinks and attributes (the signature depends on them)
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname gerdTV -srcfolder "$stage" -ov -format UDZO "$out"
hdiutil verify -quiet "$out"
echo "macos-dmg: $out"
