#!/usr/bin/env bash
set -uo pipefail

readonly CONFIG_FILE="${SP_CONFIG_FILE:-/etc/sp-traffic/config}"
readonly ENDPOINTS_FILE="${SP_ENDPOINTS_FILE:-/etc/sp-traffic/endpoints}"
readonly DATA_DIR="${SP_DATA_DIR:-/var/lib/sp-traffic}"
readonly COUNTER_DIR="${DATA_DIR}/counters"
readonly PID_DIR="${DATA_DIR}/pids"
readonly PAUSE_FILE="${DATA_DIR}/paused"
readonly PAUSE_REASON_FILE="${DATA_DIR}/pause_reason"
readonly EFFECTIVE_WORKERS_FILE="${DATA_DIR}/effective_workers"
readonly LIVE_STATS_FILE="${DATA_DIR}/live_stats"
readonly RATE_HISTORY_FILE="${DATA_DIR}/rate_history"
readonly SESSION_STARTED_FILE="${DATA_DIR}/session_started"
readonly LAST_SESSION_FILE="${DATA_DIR}/last_session"
readonly HARD_MAX_WORKERS=32
readonly RATE_HISTORY_LIMIT=60
readonly RATE_HISTORY_TRIM_THRESHOLD=90
readonly MAX_TRANSFER_TIMEOUT=1800

WORKERS=0
MAX_MBPS=0
AGGRESSIVE_MODE=1
MIN_FREE_DISK_MB=200
CONNECT_TIMEOUT=15
TRANSFER_TIMEOUT=900
CYCLE_DELAY=2
ENDPOINTS=()
SLOT_PIDS=()
RATE_HISTORY_SAMPLES=0

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
      AGGRESSIVE_MODE)
        case "$value" in
          0|1) AGGRESSIVE_MODE="$value" ;;
        esac
        ;;
      MIN_FREE_DISK_MB)
        valid_uint "$value" && MIN_FREE_DISK_MB="$value"
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
  [ "$TRANSFER_TIMEOUT" -le "$MAX_TRANSFER_TIMEOUT" ] ||
    TRANSFER_TIMEOUT="$MAX_TRANSFER_TIMEOUT"
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

stop_active_transfers() {
  local file pid
  for file in "${PID_DIR}"/curl-*.pid; do
    [ -f "$file" ] || continue
    read -r pid < "$file" || continue
    kill "$pid" 2>/dev/null || true
  done
}

enforce_disk_guard() {
  local disk_kb threshold_kb disk_mb
  [ "$MIN_FREE_DISK_MB" -gt 0 ] || return 0
  disk_kb="$(available_disk_kb)"
  valid_uint "$disk_kb" || return 0
  threshold_kb=$((MIN_FREE_DISK_MB * 1024))
  [ "$disk_kb" -ge "$threshold_kb" ] && return 0

  disk_mb=$((disk_kb / 1024))
  if [ ! -f "$PAUSE_FILE" ]; then
    printf 'disk_low:%s:%s\n' "$disk_mb" "$MIN_FREE_DISK_MB" >"${PAUSE_REASON_FILE}.tmp"
    mv -f "${PAUSE_REASON_FILE}.tmp" "$PAUSE_REASON_FILE"
    touch "$PAUSE_FILE"
    echo "sp-traffic: auto-paused with ${disk_mb} MiB free (threshold ${MIN_FREE_DISK_MB} MiB)" >&2
  fi
  stop_active_transfers
  return 1
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

  if [ "$AGGRESSIVE_MODE" -eq 1 ]; then
    target=$((cpus * 4))
    memory_slots=$((memory_kb / 32768))
  else
    target=$((cpus * 2))
    memory_slots=$((memory_kb / 65536))
  fi
  [ "$target" -ge 1 ] || target=1
  [ "$target" -le "$HARD_MAX_WORKERS" ] || target="$HARD_MAX_WORKERS"

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

add_counter() {
  local file="$1" bytes="$2" current
  bytes="${bytes%%.*}"
  bytes="${bytes%$'\r'}"
  valid_uint "$bytes" || return 0
  current="$(read_counter "$file")"
  printf '%s\n' "$((current + bytes))" >"${file}.tmp"
  mv -f "${file}.tmp" "$file"
}

record_transfer() {
  local slot="$1" download_bytes="$2" upload_bytes="$3"
  add_counter "${COUNTER_DIR}/download-session-worker-${slot}" "$download_bytes"
  add_counter "${COUNTER_DIR}/upload-session-worker-${slot}" "$upload_bytes"
}

sum_counter_prefix() {
  local prefix="$1" total=0 file value
  for file in "${COUNTER_DIR}/${prefix}"*; do
    [ -f "$file" ] || continue
    value="$(read_counter "$file")"
    total=$((total + value))
  done
  printf '%s\n' "$total"
}

snapshot_session_if_needed() {
  local started=0 last_saved=0 previous_download previous_upload
  local now duration
  if [ -r "$SESSION_STARTED_FILE" ]; then
    read -r started < "$SESSION_STARTED_FILE" || started=0
  fi
  valid_uint "$started" || started=0
  [ "$started" -gt 0 ] || return 0

  if [ -r "$LAST_SESSION_FILE" ]; then
    read -r _ _ _ last_saved < "$LAST_SESSION_FILE" || true
  fi
  valid_uint "$last_saved" || last_saved=0
  [ "$last_saved" -lt "$started" ] || return 0

  previous_download="$(sum_counter_prefix 'download-session-worker-')"
  previous_upload="$(sum_counter_prefix 'upload-session-worker-')"
  now="$(date +%s)"
  if [ "$now" -ge "$started" ]; then
    duration=$((now - started))
  else
    duration=0
  fi
  printf '%s %s %s %s\n' \
    "$previous_download" "$previous_upload" "$duration" "$now" \
    >"${LAST_SESSION_FILE}.tmp"
  mv -f "${LAST_SESSION_FILE}.tmp" "$LAST_SESSION_FILE"
}

reset_session_stats() {
  local file now
  for file in \
    "${COUNTER_DIR}"/download-session-worker-* \
    "${COUNTER_DIR}"/upload-session-worker-*; do
    [ -f "$file" ] || continue
    printf '0\n' > "$file"
  done
  now="$(date +%s)"
  printf '%s\n' "$now" >"${SESSION_STARTED_FILE}.tmp"
  mv -f "${SESSION_STARTED_FILE}.tmp" "$SESSION_STARTED_FILE"
  : > "$RATE_HISTORY_FILE"
  RATE_HISTORY_SAMPLES=0
  printf '0 0 0 0 %s\n' "$now" >"${LIVE_STATS_FILE}.tmp"
  mv -f "${LIVE_STATS_FILE}.tmp" "$LIVE_STATS_FILE"
}

cleanup_stale_runtime_files() {
  rm -f \
    "${DATA_DIR}"/size-*.tmp \
    "${DATA_DIR}"/progress-*.tmp \
    "${PID_DIR}"/curl-*.pid \
    "${LIVE_STATS_FILE}.tmp" \
    "${RATE_HISTORY_FILE}.tmp" \
    "${SESSION_STARTED_FILE}.tmp" \
    "${LAST_SESSION_FILE}.tmp"
}

trim_rate_history() {
  [ -f "$RATE_HISTORY_FILE" ] || return 0
  tail -n "$RATE_HISTORY_LIMIT" "$RATE_HISTORY_FILE" >"${RATE_HISTORY_FILE}.tmp"
  mv -f "${RATE_HISTORY_FILE}.tmp" "$RATE_HISTORY_FILE"
  RATE_HISTORY_SAMPLES="$RATE_HISTORY_LIMIT"
}

update_live_stats() {
  local file rates now download_rate upload_rate active_download active_upload
  local -a progress_files=()

  for file in "${DATA_DIR}"/progress-*.tmp; do
    [ -f "$file" ] || continue
    progress_files+=("$file")
  done

  if [ "${#progress_files[@]}" -gt 0 ]; then
    rates="$(awk -v RS='\r' '
      function bytes(value, suffix, multiplier) {
        gsub(/,/, "", value)
        suffix=substr(value, length(value), 1)
        multiplier=1
        if (suffix=="k" || suffix=="K") {
          multiplier=1024
          value=substr(value, 1, length(value)-1)
        } else if (suffix=="m" || suffix=="M") {
          multiplier=1048576
          value=substr(value, 1, length(value)-1)
        } else if (suffix=="g" || suffix=="G") {
          multiplier=1073741824
          value=substr(value, 1, length(value)-1)
        } else if (suffix=="t" || suffix=="T") {
          multiplier=1099511627776
          value=substr(value, 1, length(value)-1)
        }
        return int((value + 0) * multiplier)
      }
      {
        line=$0
        gsub(/\n/, " ", line)
        sub(/^[[:space:]]+/, "", line)
        fields=split(line, part, /[[:space:]]+/)
        if (fields >= 12 && part[1] ~ /^[0-9]+$/ && part[3] ~ /^[0-9]+$/) {
          down_rate[FILENAME]=bytes(part[12])
          up_rate[FILENAME]=bytes(part[8])
          down_active[FILENAME]=bytes(part[4])
          up_active[FILENAME]=bytes(part[6])
        }
      }
      END {
        for (name in down_rate) total_down_rate += down_rate[name]
        for (name in up_rate) total_up_rate += up_rate[name]
        for (name in down_active) total_down_active += down_active[name]
        for (name in up_active) total_up_active += up_active[name]
        printf "%.0f %.0f %.0f %.0f\n",
          total_down_rate, total_up_rate, total_down_active, total_up_active
      }
    ' "${progress_files[@]}" 2>/dev/null || printf '0 0 0 0\n')"
  else
    rates="0 0 0 0"
  fi

  read -r download_rate upload_rate active_download active_upload <<<"$rates"
  valid_uint "$download_rate" || download_rate=0
  valid_uint "$upload_rate" || upload_rate=0
  valid_uint "$active_download" || active_download=0
  valid_uint "$active_upload" || active_upload=0
  now="$(date +%s)"

  printf '%s %s %s %s %s\n' \
    "$download_rate" "$upload_rate" "$active_download" "$active_upload" "$now" \
    >"${LIVE_STATS_FILE}.tmp"
  mv -f "${LIVE_STATS_FILE}.tmp" "$LIVE_STATS_FILE"
  printf '%s %s %s\n' "$download_rate" "$upload_rate" "$now" >> "$RATE_HISTORY_FILE"
  RATE_HISTORY_SAMPLES=$((RATE_HISTORY_SAMPLES + 1))
  if [ "$RATE_HISTORY_SAMPLES" -gt "$RATE_HISTORY_TRIM_THRESHOLD" ]; then
    trim_rate_history
  fi
}

wait_while_paused() {
  while [ -f "$PAUSE_FILE" ]; do
    sleep 1
  done
}

download_once() {
  local slot="$1" url="$2"
  local size_file="${DATA_DIR}/size-${slot}.tmp"
  local progress_file="${DATA_DIR}/progress-${slot}.tmp"
  local pid_file="${PID_DIR}/curl-${slot}.pid" per_worker_kbps=0
  local -a rate_arg=() retry_args=()
  local active_workers=1 curl_pid status download_bytes=0 upload_bytes=0

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
  if [ "$AGGRESSIVE_MODE" -eq 1 ]; then
    retry_args=(--retry 5 --retry-delay 1)
  else
    retry_args=(--retry 2 --retry-delay 2)
  fi

  : > "$size_file"
  : > "$progress_file"
  curl --fail --location --show-error \
    --output /dev/null \
    --write-out '%{size_download} %{size_upload}\n' \
    --stderr "$progress_file" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TRANSFER_TIMEOUT" \
    --speed-time 30 --speed-limit 1024 \
    "${retry_args[@]}" \
    --user-agent "sp-traffic/1.4 authorized-bandwidth-test" \
    "${rate_arg[@]}" \
    "$url" >"$size_file" &
  curl_pid=$!
  printf '%s\n' "$curl_pid" > "$pid_file"
  wait "$curl_pid"
  status=$?
  rm -f "$pid_file"

  read -r download_bytes upload_bytes < "$size_file" || true
  download_bytes="${download_bytes%%.*}"
  upload_bytes="${upload_bytes%%.*}"
  valid_uint "$download_bytes" || download_bytes=0
  valid_uint "$upload_bytes" || upload_bytes=0
  record_transfer "$slot" "$download_bytes" "$upload_bytes"
  rm -f "$size_file" "$progress_file"
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
      if [ "$AGGRESSIVE_MODE" -eq 1 ]; then
        delay="$failures"
        [ "$delay" -le 15 ] || delay=15
      else
        delay=$((failures * 2))
        [ "$delay" -le 60 ] || delay=60
      fi
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
  local slot now
  for ((slot=1; slot<=HARD_MAX_WORKERS; slot++)); do
    stop_slot "$slot"
  done
  snapshot_session_if_needed
  now="$(date +%s)"
  printf '0 0 0 0 %s\n' "$now" >"${LIVE_STATS_FILE}.tmp"
  mv -f "${LIVE_STATS_FILE}.tmp" "$LIVE_STATS_FILE"
  rm -f \
    "$EFFECTIVE_WORKERS_FILE" \
    "${DATA_DIR}"/size-*.tmp \
    "${DATA_DIR}"/progress-*.tmp \
    "${PID_DIR}"/curl-*.pid
}

supervise() {
  local target slot pid tick
  while :; do
    load_config
    if enforce_disk_guard && [ ! -f "$PAUSE_FILE" ]; then
      target="$(compute_target_workers)"
    else
      target=0
    fi
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
      update_live_stats
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
  cleanup_stale_runtime_files
  snapshot_session_if_needed
  reset_session_stats
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
