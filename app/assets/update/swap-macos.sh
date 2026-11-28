#!/bin/bash
# The macOS update swap (lib/platform/mac_install.dart starts it as soon as the download is verified): waits as long
# as gerdTV runs, however it ends (the update goes in at the quit), moves the installed bundle aside, copies the new
# one into its place (ditto keeps the signature intact) and puts the old one back if that fails. It starts gerdTV
# again only when the file "reopen" exists next to this script (Install and restart writes it before quitting).
# Once installed, the download (the zip) and the unpacked bundle are deleted; after a failure the zip stays for
# another try. The new bundle was checked against the installed app's code signing requirement before this runs.
# Usage: swap-macos.sh <pid> <installed.app> <new.app> [<download.zip>]
# Debug: the log is next to this script (swap.log); GERDTV_COPY / GERDTV_OPEN replace ditto / open in tests.
pid="$1"
old="$2"
new="$3"
zip="$4"
copy="${GERDTV_COPY:-ditto}"
open="${GERDTV_OPEN:-open}"
exec >>"$(dirname "$0")/swap.log" 2>&1
# Running = the process exists and isn't a zombie (ended, not yet reaped by its parent): kill -0 alone still
# succeeds for a zombie, and with no time limit on this wait it would never end.
running() {
  kill -0 "$pid" 2>/dev/null && [[ "$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')" != Z* ]]
}
while running; do
  sleep 0.5
done
backup="${old%.app}.previous.app"
rm -rf "$backup"
mv "$old" "$backup" || { echo "swap: can't move $old aside; nothing changed"; exit 1; }
if $copy "$new" "$old"; then
  rm -rf "$backup"
  echo "swap: installed"
  rm -rf "$new"
  [[ -n "$zip" ]] && rm -f "$zip" && echo "swap: deleted the download $zip"
else
  rm -rf "$old"
  mv "$backup" "$old"
  echo "swap: copy failed; the previous version is back"
fi
if [[ -f "$(dirname "$0")/reopen" ]]; then $open "$old"; fi
