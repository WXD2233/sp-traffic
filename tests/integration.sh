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
AGGRESSIVE_MODE=1
MIN_FREE_DISK_MB=200
CONNECT_TIMEOUT=5
TRANSFER_TIMEOUT=30
CYCLE_DELAY=2
EOF
printf 'http://127.0.0.1:%s/test.bin\n' "$TEST_PORT" >"$TEST_DIR/config/endpoints"
printf 'stale\n' >"$TEST_DIR/data/progress-99.tmp"
printf 'stale\n' >"$TEST_DIR/data/size-99.tmp"
printf '999999\n' >"$TEST_DIR/data/pids/curl-99.pid"

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
[ ! -e "$TEST_DIR/data/progress-99.tmp" ]
[ ! -e "$TEST_DIR/data/size-99.tmp" ]
[ ! -e "$TEST_DIR/data/pids/curl-99.pid" ]
[ -s "$TEST_DIR/data/live_stats" ] || {
  echo "expected live_stats to be created" >&2
  exit 1
}
[ "$(awk '{print NF}' "$TEST_DIR/data/live_stats")" -eq 5 ] || {
  echo "expected live_stats to contain five fields" >&2
  exit 1
}
history_lines="$(wc -l < "$TEST_DIR/data/rate_history")"
[ "$history_lines" -le 90 ] || {
  echo "expected bounded rate history, got $history_lines lines" >&2
  exit 1
}
runtime_kb="$(du -sk "$TEST_DIR/data" | awk '{print $1}')"
[ "$runtime_kb" -lt 1024 ] || {
  echo "expected runtime data to remain below 1 MiB in the single-worker test, got ${runtime_kb} KiB" >&2
  exit 1
}
kill "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true
WORKER_PID=""

session_total="$(awk '{sum += $1} END {print sum + 0}' "$TEST_DIR"/data/counters/download-session-worker-*)"
[ "$session_total" -ge 262144 ] || {
  echo "expected session download statistics, got $session_total bytes" >&2
  exit 1
}
total="$session_total"
upload_total="$(awk '{sum += $1} END {print sum + 0}' "$TEST_DIR"/data/counters/upload-session-worker-*)"
[ "$upload_total" -ge 0 ] || {
  echo "expected upload statistics to be numeric" >&2
  exit 1
}
read -r last_download _ _ _ <"$TEST_DIR/data/last_session"
[ "$last_download" -ge "$session_total" ] || {
  echo "expected worker shutdown to preserve the last session" >&2
  exit 1
}

rm -f "$TEST_DIR/data/paused" "$TEST_DIR/data/pause_reason"
printf 'MIN_FREE_DISK_MB=999999999\n' >>"$TEST_DIR/config/config"

SP_CONFIG_FILE="$TEST_DIR/config/config" \
SP_ENDPOINTS_FILE="$TEST_DIR/config/endpoints" \
SP_DATA_DIR="$TEST_DIR/data" \
  "${WORKER_COMMAND[@]}" &
WORKER_PID=$!

sleep 2
[ -f "$TEST_DIR/data/paused" ] || {
  echo "expected low-disk guard to create the pause file" >&2
  exit 1
}
grep -q '^disk_low:' "$TEST_DIR/data/pause_reason"
session_after_restart="$(awk '{sum += $1} END {print sum + 0}' \
  "$TEST_DIR"/data/counters/download-session-worker-*)"
[ "$session_after_restart" -eq 0 ] || {
  echo "expected a restarted worker to reset session statistics" >&2
  exit 1
}
read -r previous_download _ _ _ <"$TEST_DIR/data/last_session"
[ "$previous_download" -eq "$last_download" ] || {
  echo "expected the last-session record to survive restart" >&2
  exit 1
}
kill "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true
WORKER_PID=""

printf 'systemd\n' >"$TEST_DIR/config/backend"
id() {
  if [ "${1:-}" = "-u" ]; then
    printf '0\n'
  else
    command id "$@"
  fi
}
systemctl() {
  case "${1:-}" in
    is-active)
      [ "${MOCK_ACTIVE:-0}" = "1" ]
      ;;
    *) return 0 ;;
  esac
}
sysctl() {
  printf 'mock\n'
}
tput() {
  printf '130\n'
}
install() {
  local -a arguments=("$@")
  local count="${#arguments[@]}"
  command cp -- "${arguments[count-2]}" "${arguments[count-1]}"
}
export -f id systemctl sysctl tput install
export MOCK_ACTIVE=1
mock_now="$(date +%s)"
printf '12345\n' >"$TEST_DIR/data/counters/download-session-worker-1"
printf '678\n' >"$TEST_DIR/data/counters/upload-session-worker-1"
printf '%s\n' "$((mock_now - 20))" >"$TEST_DIR/data/session_started"
printf '0 0 55 22 %s\n' "$mock_now" >"$TEST_DIR/data/live_stats"
SP_CONFIG_DIR="$TEST_DIR/config" \
SP_DATA_DIR="$TEST_DIR/data" \
  "$ROOT_DIR/sp" stop >"$TEST_DIR/stop.txt"
read -r stopped_download stopped_upload stopped_duration _ <"$TEST_DIR/data/last_session"
[ "$stopped_download" -eq 12400 ]
[ "$stopped_upload" -eq 700 ]
[ "$stopped_duration" -ge 20 ]

export MOCK_ACTIVE=0
SP_CONFIG_DIR="$TEST_DIR/config" \
SP_DATA_DIR="$TEST_DIR/data" \
  "$ROOT_DIR/sp" refresh 0 >"$TEST_DIR/refresh.txt"
grep -q '^DASHBOARD_REFRESH_SECONDS=0$' "$TEST_DIR/config/config"
SP_CONFIG_DIR="$TEST_DIR/config" \
SP_DATA_DIR="$TEST_DIR/data" \
  "$ROOT_DIR/sp" refresh 12 >>"$TEST_DIR/refresh.txt"
grep -q '^DASHBOARD_REFRESH_SECONDS=12$' "$TEST_DIR/config/config"
if SP_CONFIG_DIR="$TEST_DIR/config" \
  SP_DATA_DIR="$TEST_DIR/data" \
  "$ROOT_DIR/sp" refresh 3601 >/dev/null 2>&1; then
  echo "refresh interval above 3600 seconds should fail" >&2
  exit 1
fi

SP_CONFIG_DIR="$TEST_DIR/config" \
SP_DATA_DIR="$TEST_DIR/data" \
  "$ROOT_DIR/sp" dashboard >"$TEST_DIR/dashboard.txt"
grep -q '开始/继续' "$TEST_DIR/dashboard.txt"
grep -q '本次运行' "$TEST_DIR/dashboard.txt"
grep -q '上次记录' "$TEST_DIR/dashboard.txt"
grep -q 'T) 刷新间隔' "$TEST_DIR/dashboard.txt"
grep -q '刷新 已停止' "$TEST_DIR/dashboard.txt"
grep -Eq '本次运行.*下载[[:space:]]+0\.00 B.*上传[[:space:]]+0\.00 B' \
  "$TEST_DIR/dashboard.txt"
if grep -q '历史总计' "$TEST_DIR/dashboard.txt"; then
  echo "dashboard should show the last session instead of historical totals" >&2
  exit 1
fi

printf 'Worker integration passed (%s bytes); last-session and low-disk guard passed.\n' "$total"
