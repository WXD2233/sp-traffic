#!/usr/bin/env bash
set -uo pipefail

readonly CONFIG_FILE="${SP_CONFIG_FILE:-/etc/sp-traffic/config}"
readonly ENDPOINTS_FILE="${SP_ENDPOINTS_FILE:-/etc/sp-traffic/endpoints}"
readonly DATA_DIR="${SP_DATA_DIR:-/var/lib/sp-traffic}"
readonly COUNTER_DIR="${DATA_DIR}/counters"
readonly PID_DIR="${DATA_DIR}/pids"
readonly PAUSE_FILE="${DATA_DIR}/paused"
readonly EFFECTIVE_WORKERS_FILE="${DATA_DIR}/effective_workers"
readonly HARD_MAX_WORKERS=16

WORKERS=0
MAX_MBPS=0
CONNECT_TIMEOUT=15
TRANSFER_TIMEOUT=900
CYCLE_DELAY=2
ENDPOINTS=()
SLOT_PIDS=()

valid_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

load_config() {
  local key value
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"
    case "$key" in
      WORKERS)
        valid_uint "$value" && WORKERS="$value"
        ;;
      MAX_MBPS)
        valid_uint "$value" && MAX_MBPS="$value"
        ;;
      CONNECT_TIMEOUT)
        valid_uint "$value" && CONNECT_TIMEOUT="$value"
        ;;
      TRANSFER_TIMEOUT)
        valid_uint "$value" && TRANSFER_TIMEOUT="$value"
        ;;
      CYCLE_DELAY)
        valid_uint "$value" && CYCLE_DELAY="$value"
        ;;
    esac
  done < "$CONFIG_FILE"

  [ "$WORKERS" -le "$HARD_MAX_WORKERS" ] || WORKERS="$HARD_MAX_WORKERS"
  [ "$CONNECT_TIMEOUT" -ge 1 ] || CONNECT_TIMEOUT=15
  [ "$TRANSFER_TIMEOUT" -ge 30 ] || TRANSFER_TIMEOUT=30
  [ "$CYCLE_DELAY" -ge 2 ] || CYCLE_DELAY=2
}

load_endpoints() {
  local line
  ENDPOINTS=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      http://*|https://*) ENDPOINTS+=("$line") ;;
    esac
  done < "$ENDPOINTS_FILE"
}

available_memory_kb() {
  awk '/^MemAvailable:/ {print $2; found=1} END {if (!found) print 131072}' /proc/meminfo 2>/dev/null
}

available_disk_kb() {
  df -Pk "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4}'
}

cpu_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
}

compute_target_workers() {
  local cpus memory_kb disk_kb target memory_slots
  cpus="$(cpu_count)"
  memory_kb="$(available_memory_kb)"
  disk_kb="$(available_disk_kb)"
  valid_uint "$cpus" || cpus=1
  valid_uint "$memory_kb" || memory_kb=131072
  valid_uint "$disk_kb" || disk_kb=65536

  target=$((cpus * 2))
  [ "$target" -ge 1 ] || target=1
  [ "$target" -le "$HARD_MAX_WORKERS" ] || target="$HARD_MAX_WORKERS"

  memory_slots=$((memory_kb / 65536))
  [ "$memory_slots" -ge 1 ] || memory_slots=1
  [ "$target" -le "$memory_slots" ] || target="$memory_slots"

  if [ "$disk_kb" -lt 65536 ]; then
    target=1
  elif [ "$disk_kb" -lt 262144 ] && [ "$target" -gt 2 ]; then
    target=2
  fi

  if [ "$WORKERS" -gt 0 ] && [ "$target" -gt "$WORKERS" ]; then
    target="$WORKERS"
  fi
  printf '%s\n' "$target"
}

read_counter() {
  local file="$1" value=0
  if [ -f "$file" ]; then
    read -r value < "$file" || value=0
  fi
  value="${value%$'\r'}"
  valid_uint "$value" || value=0
  printf '%s\n' "$value"
}

record_bytes() {
  local slot="$1" bytes="$2" file current
  bytes="${bytes%%.*}"
  bytes="${bytes%$'\r'}"
  valid_uint "$bytes" || return 0
  file="${COUNTER_DIR}/worker-${slot}"
  current="$(read_counter "$file")"
  printf '%s\n' "$((current + bytes))" >"${file}.tmp"
  mv -f "${file}.tmp" "$file"
}

wait_while_paused() {
  while [ -f "$PAUSE_FILE" ]; do
    sleep 1
  done
}

download_once() {
  local slot="$1" url="$2"
  local size_file="${DATA_DIR}/size-${slot}.tmp"
  local pid_file="${PID_DIR}/curl-${slot}.pid" per_worker_kbps=0
  local -a rate_arg=()
  local active_workers=1 curl_pid status bytes

  if [ "$MAX_MBPS" -gt 0 ]; then
    if [ -f "$EFFECTIVE_WORKERS_FILE" ]; then
      read -r active_workers < "$EFFECTIVE_WORKERS_FILE" || active_workers=1
    fi
    valid_uint "$active_workers" || active_workers=1
    [ "$active_workers" -ge 1 ] || active_workers=1
    per_worker_kbps=$((MAX_MBPS * 1000 / 8 / active_workers))
    [ "$per_worker_kbps" -ge 1 ] || per_worker_kbps=1
    rate_arg=(--limit-rate "${per_worker_kbps}K")
  fi

  : > "$size_file"
  curl --fail --location --silent --show-error \
    --output /dev/null \
    --write-out '%{size_download}\n' \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TRANSFER_TIMEOUT" \
    --speed-time 30 --speed-limit 1024 \
    --retry 2 --retry-delay 2 \
    --user-agent "sp-traffic/1.0 authorized-bandwidth-test" \
    "${rate_arg[@]}" \
    "$url" >"$size_file" &
  curl_pid=$!
  printf '%s\n' "$curl_pid" > "$pid_file"
  wait "$curl_pid"
  status=$?
  rm -f "$pid_file"

  if [ "$status" -eq 0 ]; then
    read -r bytes < "$size_file" || bytes=0
    record_bytes "$slot" "$bytes"
  fi
  rm -f "$size_file"
  return "$status"
}

run_slot() {
  local slot="$1" endpoint_index failures=0 delay
  while :; do
    wait_while_paused
    endpoint_index=$(((slot + failures) % ${#ENDPOINTS[@]}))
    if download_once "$slot" "${ENDPOINTS[$endpoint_index]}"; then
      failures=0
      sleep "$CYCLE_DELAY"
    else
      if [ -f "$PAUSE_FILE" ]; then
        continue
      fi
      failures=$((failures + 1))
      delay=$((failures * 2))
      [ "$delay" -le 60 ] || delay=60
      sleep "$delay"
    fi
  done
}

stop_slot() {
  local slot="$1" pid
  pid="${SLOT_PIDS[slot]:-}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  SLOT_PIDS[slot]=""
  if [ -f "${PID_DIR}/curl-${slot}.pid" ]; then
    kill "$(cat "${PID_DIR}/curl-${slot}.pid")" 2>/dev/null || true
    rm -f "${PID_DIR}/curl-${slot}.pid"
  fi
}

cleanup() {
  local slot
  for ((slot=1; slot<=HARD_MAX_WORKERS; slot++)); do
    stop_slot "$slot"
  done
  rm -f "$EFFECTIVE_WORKERS_FILE" "${DATA_DIR}"/size-*.tmp "${PID_DIR}"/curl-*.pid
}

supervise() {
  local target slot pid tick
  while :; do
    load_config
    target="$(compute_target_workers)"
    printf '%s\n' "$target" > "$EFFECTIVE_WORKERS_FILE"

    for ((slot=1; slot<=HARD_MAX_WORKERS; slot++)); do
      pid="${SLOT_PIDS[slot]:-}"
      if [ "$slot" -le "$target" ]; then
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
          run_slot "$slot" &
          SLOT_PIDS[slot]=$!
        fi
      elif [ -n "$pid" ]; then
        stop_slot "$slot"
      fi
    done
    for ((tick=0; tick<30; tick++)); do
      sleep 1
    done
  done
}

main() {
  command -v curl >/dev/null 2>&1 || {
    echo "sp-traffic: curl is required" >&2
    exit 1
  }
  [ -r "$CONFIG_FILE" ] || {
    echo "sp-traffic: config is not readable" >&2
    exit 1
  }
  [ -r "$ENDPOINTS_FILE" ] || {
    echo "sp-traffic: endpoints file is not readable" >&2
    exit 1
  }

  mkdir -p "$COUNTER_DIR" "$PID_DIR"
  load_config
  load_endpoints
  [ "${#ENDPOINTS[@]}" -gt 0 ] || {
    echo "sp-traffic: no authorized endpoint configured" >&2
    exit 2
  }

  trap cleanup EXIT
  trap 'exit 0' INT TERM
  supervise
}

main "$@"
