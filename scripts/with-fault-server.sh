#!/usr/bin/env bash
# Runs a command with the testkit's fault server alongside (crates/gerdtv-testkit/src/fault.rs) and its URL in
# GERDTV_FAULT_SERVER; the server stops when the command ends. Used by `just test-integration` and `just mac-check`.
# Usage: scripts/with-fault-server.sh <command> [args...]
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build -q -p gerdtv-testkit --example fault_server
log="$(mktemp)"
./target/debug/examples/fault_server > "$log" &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 100); do [[ -s "$log" ]] && break; sleep 0.1; done
GERDTV_FAULT_SERVER="$(head -1 "$log")"
[[ -n "$GERDTV_FAULT_SERVER" ]] || { echo "with-fault-server: the server did not start"; exit 1; }
export GERDTV_FAULT_SERVER
"$@"
