#!/bin/bash
# The macOS update swap (lib/platform/mac_install.dart starts it, then the app quits): waits until gerdTV has quit,
# moves the installed bundle aside, copies the new one into its place (ditto keeps the signature intact), puts the
# old one back if that fails, and starts gerdTV again. The new bundle was checked against the installed app's code
# signing requirement before this runs.
# Usage: swap-macos.sh <pid> <installed.app> <new.app>
# Debug: the log is next to this script (swap.log); GERDTV_COPY / GERDTV_OPEN replace ditto / open in tests.
pid="$1"
old="$2"
new="$3"
copy="${GERDTV_COPY:-ditto}"
open="${GERDTV_OPEN:-open}"
exec >>"$(dirname "$0")/swap.log" 2>&1
for _ in $(seq 1 120); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$pid" 2>/dev/null; then
  echo "swap: gerdTV ($pid) is still running after 60 s; nothing changed"
  exit 1
fi
backup="${old%.app}.previous.app"
rm -rf "$backup"
mv "$old" "$backup" || { echo "swap: can't move $old aside; nothing changed"; exit 1; }
if $copy "$new" "$old"; then
  rm -rf "$backup"
  echo "swap: installed"
else
  rm -rf "$old"
  mv "$backup" "$old"
  echo "swap: copy failed; the previous version is back"
fi
$open "$old"
