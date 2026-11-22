#!/usr/bin/env bash
# Runs a command with the testkit's fault server (crates/gerdtv-testkit/src/fault.rs) and mock Xtream Codes panel
# (src/mock_xc.rs) alongside, their URLs in GERDTV_FAULT_SERVER and GERDTV_MOCK_XC; both stop when the command ends. Used by `just test-integration` and `just mac-check`.
# Usage: scripts/with-fault-server.sh <command> [args...]
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build -q -p gerdtv-testkit --example fault_server --example mock_xc
log="$(mktemp)"
xclog="$(mktemp)"
./target/debug/examples/fault_server > "$log" &
pid=$!
./target/debug/examples/mock_xc > "$xclog" &
xcpid=$!
trap 'kill $pid $xcpid 2>/dev/null || true; rm -f "$log" "$xclog"' EXIT
for _ in $(seq 100); do [[ -s "$log" && -s "$xclog" ]] && break; sleep 0.1; done
GERDTV_FAULT_SERVER="$(head -1 "$log")"
GERDTV_MOCK_XC="$(head -1 "$xclog")"
[[ -n "$GERDTV_FAULT_SERVER" && -n "$GERDTV_MOCK_XC" ]] || { echo "with-fault-server: a server did not start"; exit 1; }
export GERDTV_FAULT_SERVER GERDTV_MOCK_XC
"$@"
