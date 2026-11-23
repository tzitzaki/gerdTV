#!/usr/bin/env bash
# Integration test hang watchdog. Linux CI hung four times (#18, #26, #37, #41) with the app's event loop blocked,
# so no Dart test timeout could fire and only the job's 60-minute limit ended it, without a clue where. This runs
# the command, and after <quiet-seconds> without any output it writes the native stack traces of the running app
# (gdb; CI installs it) into the log, then ends the run with a failure.
# Usage: scripts/with-hang-watch.sh <quiet-seconds> <command...>
# Debug: the stacks are the app's threads; look for the main (platform) thread waiting inside libmpv/media_kit.
set -uo pipefail
quiet="$1"
shift
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

"$@" > >(tee "$log") 2>&1 &
pid=$!
last=-1
since=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
  sleep 15
  size=$(stat -c %s "$log")
  if [[ "$size" != "$last" ]]; then
    last=$size
    since=$(date +%s)
    continue
  fi
  (( $(date +%s) - since < quiet )) && continue
  echo "hang-watch: no output for ${quiet} s; the app's native stacks follow"
  for app in $(pgrep -x gerdtv); do  # the app's process name exactly (a pattern would match shells too)
    echo "hang-watch: == process $app"
    if command -v gdb >/dev/null; then
      # CI runners restrict ptrace to children; sudo works there without a password.
      sudo -n gdb -p "$app" -batch -ex 'thread apply all bt' 2>&1 || gdb -p "$app" -batch -ex 'thread apply all bt' 2>&1
    else
      for t in /proc/"$app"/task/*; do echo "thread $(cat "$t"/comm): waits in $(cat "$t"/wchan 2>/dev/null)"; done
    fi
  done
  pkill -x gerdtv
  pkill -P "$pid"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "hang-watch: stopped the hanging run"
  exit 1
done
wait "$pid"
