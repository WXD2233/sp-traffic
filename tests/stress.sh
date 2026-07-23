#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEST_PORT="${TEST_PORT:-18766}"
TEST_DIR="$(mktemp -d)"
SERVER_DIRECTORY="$TEST_DIR/www"
SERVER_PID=""
SUPERVISOR_PID=""
CRASH_CYCLES="${SP_STRESS_CRASH_CYCLES:-5}"

valid_pid() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 1 ] ;;
  esac
}

kill_process_group() {
  local pid="${1:-}" signal="${2:-TERM}"
  valid_pid "$pid" || return 0
  kill -s "$signal" -- "-${pid}" 2>/dev/null \
    || kill -s "$signal" "$pid" 2>/dev/null \
    || true
}

cleanup() {
  set +e
  if valid_pid "$SUPERVISOR_PID"; then
    kill "$SUPERVISOR_PID" 2>/dev/null
    wait "$SUPERVISOR_PID" 2>/dev/null
  fi
  if valid_pid "$SERVER_PID"; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT INT TERM

start_supervisor() {
  SP_CONFIG_FILE="$TEST_DIR/config/config" \
  SP_ENDPOINTS_FILE="$TEST_DIR/config/endpoints" \
  SP_DATA_DIR="$TEST_DIR/data" \
  SP_RESTART_BASE_DELAY=1 \
  SP_RESTART_MAX_DELAY=2 \
    "$ROOT_DIR/worker.sh" >/dev/null 2>&1 &
  SUPERVISOR_PID=$!
}

wait_for_child() {
  local previous="${1:-}" attempt pid=""
  for ((attempt=1; attempt<=80; attempt++)); do
    if [ -r "$TEST_DIR/data/supervised_worker.pid" ]; then
      read -r pid <"$TEST_DIR/data/supervised_worker.pid" || pid=""
      if valid_pid "$pid" \
        && [ "$pid" != "$previous" ] \
        && kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
    sleep 0.25
  done
  echo "timed out waiting for a live replacement worker" >&2
  return 1
}

assert_no_old_descendants() {
  local pid
  for pid in "$@"; do
    if valid_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
      echo "orphaned worker descendant is still alive: $pid" >&2
      return 1
    fi
  done
}

capture_descendants() {
  local pid_file pid
  for pid_file in "$TEST_DIR"/data/pids/*.pid; do
    [ -e "$pid_file" ] || continue
    read -r pid <"$pid_file" || pid=""
    valid_pid "$pid" && printf '%s\n' "$pid"
  done
}

session_download_total() {
  local counter_file total=0 value
  for counter_file in "$TEST_DIR"/data/counters/download-session-worker-*; do
    [ -e "$counter_file" ] || continue
    read -r value <"$counter_file" || value=0
    case "$value" in
      ''|*[!0-9]*) value=0 ;;
    esac
    total=$((total + value))
  done
  printf '%s\n' "$total"
}

mkdir -p \
  "$TEST_DIR/config" \
  "$TEST_DIR/data/counters" \
  "$TEST_DIR/data/pids" \
  "$TEST_DIR/www"

dd if=/dev/zero of="$TEST_DIR/www/test.bin" bs=1048576 count=4 status=none
printf '%s\n' \
  'WORKERS=4' \
  'MAX_MBPS=0' \
  'AGGRESSIVE_MODE=1' \
  'MIN_FREE_DISK_MB=0' \
  'CONNECT_TIMEOUT=5' \
  'TRANSFER_TIMEOUT=30' \
  'CYCLE_DELAY=1' \
  >"$TEST_DIR/config/config"
printf 'http://127.0.0.1:%s/test.bin\n' "$TEST_PORT" >"$TEST_DIR/config/endpoints"

if [[ "$PYTHON_BIN" == *.exe ]] && command -v cygpath >/dev/null 2>&1; then
  SERVER_DIRECTORY="$(cygpath -w "$SERVER_DIRECTORY")"
fi

"$PYTHON_BIN" -m http.server "$TEST_PORT" \
  --bind 127.0.0.1 \
  --directory "$SERVER_DIRECTORY" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5; do
  if curl --fail --silent --output /dev/null \
    "http://127.0.0.1:${TEST_PORT}/test.bin"; then
    break
  fi
  sleep 1
done
curl --fail --silent --output /dev/null \
  "http://127.0.0.1:${TEST_PORT}/test.bin"

start_supervisor
child_pid="$(wait_for_child)"
sleep 2
read -r original_started <"$TEST_DIR/data/session_started"
case "$original_started" in
  ''|*[!0-9]*)
    echo "session_started is not numeric" >&2
    exit 1
    ;;
esac
previous_total="$(session_download_total)"

for ((cycle=1; cycle<=CRASH_CYCLES; cycle++)); do
  if [ "$cycle" -eq 1 ]; then
    for ((sample=1; sample<=200; sample++)); do
      printf '1 0 %s\n' "$(date +%s)" >>"$TEST_DIR/data/rate_history"
    done
  fi
  mapfile -t old_descendants < <(capture_descendants)
  kill -KILL "$child_pid"
  replacement_pid="$(wait_for_child "$child_pid")"
  sleep 0.5
  assert_no_old_descendants "$child_pid" "${old_descendants[@]}"
  child_pid="$replacement_pid"

  read -r resumed_started <"$TEST_DIR/data/session_started"
  [ "$resumed_started" = "$original_started" ] || {
    echo "worker crash reset the active session on cycle $cycle" >&2
    exit 1
  }
  read -r run_state _ <"$TEST_DIR/data/run_state"
  [ "$run_state" = "active" ] || {
    echo "run state was not restored after crash cycle $cycle" >&2
    exit 1
  }
  current_total="$(session_download_total)"
  [ "$current_total" -ge "$previous_total" ] || {
    echo "session counters decreased after crash cycle $cycle" >&2
    exit 1
  }
  previous_total="$current_total"
done

printf 'user\n' >"$TEST_DIR/data/pause_reason"
: >"$TEST_DIR/data/paused"
paused_child="$child_pid"
kill -KILL "$paused_child"
child_pid="$(wait_for_child "$paused_child")"
sleep 0.5
[ -f "$TEST_DIR/data/paused" ] || {
  echo "worker crash did not preserve the paused state" >&2
  exit 1
}
grep -q '^user$' "$TEST_DIR/data/pause_reason"
rm -f "$TEST_DIR/data/paused" "$TEST_DIR/data/pause_reason"

read -r resumed_started <"$TEST_DIR/data/session_started"
[ "$resumed_started" = "$original_started" ] || {
  echo "paused-state crash reset the active session" >&2
  exit 1
}

history_lines="$(wc -l <"$TEST_DIR/data/rate_history")"
[ "$history_lines" -le 90 ] || {
  echo "rate history exceeded its 90-line limit: $history_lines" >&2
  exit 1
}
session_total="$(session_download_total)"
[ "$session_total" -gt 0 ] || {
  echo "expected non-zero transfer counters after stress run" >&2
  exit 1
}

[ -s "$TEST_DIR/data/last_exit" ] || {
  echo "expected a fixed-size last-exit record" >&2
  exit 1
}
[ "$(awk '{print NF}' "$TEST_DIR/data/last_exit")" -eq 4 ] || {
  echo "last-exit record must contain exactly four fields" >&2
  exit 1
}
read -r _ _ restart_failures restart_wait <"$TEST_DIR/data/last_exit"
[ "$restart_failures" -ge "$((CRASH_CYCLES + 1))" ] || {
  echo "restart failure counter did not track every forced crash" >&2
  exit 1
}
[ "$restart_wait" -le 2 ] || {
  echo "restart backoff exceeded the configured two-second cap" >&2
  exit 1
}
last_exit_bytes="$(wc -c <"$TEST_DIR/data/last_exit")"
[ "$last_exit_bytes" -lt 256 ] || {
  echo "last-exit record grew unexpectedly: $last_exit_bytes bytes" >&2
  exit 1
}
if find "$TEST_DIR/data" -type f -name '*.log' -print -quit | grep -q .; then
  echo "runtime data must not contain append-only log files" >&2
  exit 1
fi
runtime_kb="$(du -sk "$TEST_DIR/data" | awk '{print $1}')"
[ "$runtime_kb" -lt 4096 ] || {
  echo "runtime data exceeded the 4 MiB stress-test budget: ${runtime_kb} KiB" >&2
  exit 1
}

parent_session="$resumed_started"
orphaned_child="$child_pid"
kill -KILL "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID" 2>/dev/null || true
SUPERVISOR_PID=""
kill_process_group "$orphaned_child" KILL
sleep 0.5

start_supervisor
child_pid="$(wait_for_child "$orphaned_child")"
sleep 0.5
read -r resumed_started <"$TEST_DIR/data/session_started"
[ "$resumed_started" = "$parent_session" ] || {
  echo "supervisor restart did not resume the interrupted session" >&2
  exit 1
}

final_child="$child_pid"
kill "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID" 2>/dev/null || true
SUPERVISOR_PID=""
read -r run_state _ <"$TEST_DIR/data/run_state"
[ "$run_state" = "stopped" ] || {
  echo "graceful stop did not persist the stopped state" >&2
  exit 1
}
[ ! -e "$TEST_DIR/data/supervised_worker.pid" ] || {
  echo "graceful stop left a stale supervised-worker PID" >&2
  exit 1
}
assert_no_old_descendants "$final_child"
[ -s "$TEST_DIR/data/last_session" ] || {
  echo "graceful stop did not save the last session" >&2
  exit 1
}

printf \
  'Crash stress passed: %s worker crashes, paused-state recovery, supervisor recovery; runtime data %s KiB.\n' \
  "$((CRASH_CYCLES + 1))" "$runtime_kb"
