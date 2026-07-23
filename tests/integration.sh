#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEST_PORT="${TEST_PORT:-18765}"
TEST_DIR="$(mktemp -d)"
SERVER_PID=""
WORKER_PID=""
SERVER_DIRECTORY="$TEST_DIR/www"
WORKER_COMMAND=("$ROOT_DIR/worker.sh")

cleanup() {
  [ -z "$WORKER_PID" ] || kill "$WORKER_PID" 2>/dev/null || true
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p \
  "$TEST_DIR/config" \
  "$TEST_DIR/data/counters" \
  "$TEST_DIR/data/pids" \
  "$TEST_DIR/www"

dd if=/dev/zero of="$TEST_DIR/www/test.bin" bs=1024 count=256 status=none
cat >"$TEST_DIR/config/config" <<'EOF'
WORKERS=1
MAX_MBPS=0
CONNECT_TIMEOUT=5
TRANSFER_TIMEOUT=30
CYCLE_DELAY=2
EOF
printf 'http://127.0.0.1:%s/test.bin\n' "$TEST_PORT" >"$TEST_DIR/config/endpoints"

if [[ "$PYTHON_BIN" == *.exe ]] && command -v cygpath >/dev/null 2>&1; then
  SERVER_DIRECTORY="$(cygpath -w "$SERVER_DIRECTORY")"
fi

"$PYTHON_BIN" -m http.server "$TEST_PORT" \
  --bind 127.0.0.1 \
  --directory "$SERVER_DIRECTORY" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5; do
  if curl --fail --silent --output /dev/null "http://127.0.0.1:${TEST_PORT}/test.bin"; then
    break
  fi
  sleep 1
done
curl --fail --silent --output /dev/null "http://127.0.0.1:${TEST_PORT}/test.bin"

if [ "${SP_TEST_XTRACE:-0}" = "1" ]; then
  WORKER_COMMAND=(bash -x "$ROOT_DIR/worker.sh")
fi

SP_CONFIG_FILE="$TEST_DIR/config/config" \
SP_ENDPOINTS_FILE="$TEST_DIR/config/endpoints" \
SP_DATA_DIR="$TEST_DIR/data" \
  "${WORKER_COMMAND[@]}" &
WORKER_PID=$!

sleep 7
kill "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true
WORKER_PID=""

total="$(awk '{sum += $1} END {print sum + 0}' "$TEST_DIR"/data/counters/worker-*)"
[ "$total" -ge 262144 ] || {
  echo "expected at least one completed 256 KiB download, got $total bytes" >&2
  exit 1
}

printf 'Worker integration passed (%s bytes).\n' "$total"
