#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
# Use a Python environment with cryptography installed (same dependency as Linux SDK).
python="${MUSE_TEST_PYTHON:-python3}"
port_file="$(mktemp -t muse-relay-port)"
rm -f "$port_file"
server_log="$(mktemp -t muse-relay-server)"
"$python" "$repo/ios/tools/muse_protocol_test_server.py" --port-file "$port_file" >"$server_log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -f "$port_file" "$server_log"' EXIT
for ((i=0;i<100;i++)); do
  [[ -s "$port_file" ]] && break
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$server_log"; exit 1; fi
  sleep 0.1
done
[[ -s "$port_file" ]] || { echo 'Fixture failed to start'; exit 1; }
export MUSE_TEST_PORT="$(cat "$port_file")"
export TEST_RUNNER_MUSE_TEST_PORT="$MUSE_TEST_PORT"
if [[ $# -gt 0 ]]; then "$@"; else swift test --package-path "$repo/ios/MusePocketCore"; fi
if [[ -s "$server_log" ]]; then cat "$server_log"; exit 1; fi
