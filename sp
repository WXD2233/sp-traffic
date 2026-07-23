#!/usr/bin/env bash
set -uo pipefail

readonly INSTALL_DIR="${SP_INSTALL_DIR:-/opt/sp-traffic}"
readonly CONFIG_DIR="${SP_CONFIG_DIR:-/etc/sp-traffic}"
readonly DATA_DIR="${SP_DATA_DIR:-/var/lib/sp-traffic}"
readonly CONFIG_FILE="${CONFIG_DIR}/config"
readonly ENDPOINTS_FILE="${CONFIG_DIR}/endpoints"
readonly BACKEND_FILE="${CONFIG_DIR}/backend"
readonly PAUSE_FILE="${DATA_DIR}/paused"
readonly PAUSE_REASON_FILE="${DATA_DIR}/pause_reason"
readonly LIVE_STATS_FILE="${DATA_DIR}/live_stats"
readonly RATE_HISTORY_FILE="${DATA_DIR}/rate_history"
readonly SESSION_STARTED_FILE="${DATA_DIR}/session_started"
readonly LAST_SESSION_FILE="${DATA_DIR}/last_session"
readonly LAST_EXIT_FILE="${DATA_DIR}/last_exit"
readonly HARD_MAX_WORKERS=32
readonly DEFAULT_DASHBOARD_REFRESH_SECONDS=10
readonly MAX_DASHBOARD_REFRESH_SECONDS=3600
readonly DEFAULT_ENDPOINT="${SP_DEFAULT_ENDPOINT:-https://sin-speed.hetzner.com/10GB.bin}"

color() {
  local code="$1"
  shift
  printf '\033[%sm%s\033[0m\n' "$code" "$*"
}

info() { color '1;34' "$*"; }
ok() { color '1;32' "$*"; }
warn() { color '1;33' "$*" >&2; }
die() { color '1;31' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  fi
  die "此操作需要 root 权限，请运行: su -c 'sp'"
}

backend() {
  [ -r "$BACKEND_FILE" ] || die "未找到安装信息，请重新安装"
  cat "$BACKEND_FILE"
}

service_start() {
  case "$(backend)" in
    systemd) systemctl start sp-traffic.service ;;
    openrc) rc-service sp-traffic start ;;
    sysv) /etc/init.d/sp-traffic start ;;
    *) die "未知服务后端" ;;
  esac
}

service_stop() {
  save_current_as_last
  case "$(backend)" in
    systemd) systemctl stop sp-traffic.service ;;
    openrc) rc-service sp-traffic stop ;;
    sysv) /etc/init.d/sp-traffic stop ;;
  esac
}

service_restart() {
  save_current_as_last
  case "$(backend)" in
    systemd) systemctl restart sp-traffic.service ;;
    openrc) rc-service sp-traffic restart ;;
    sysv) /etc/init.d/sp-traffic restart ;;
  esac
}

service_is_active() {
  case "$(backend)" in
    systemd) systemctl is-active --quiet sp-traffic.service ;;
    openrc) rc-service sp-traffic status >/dev/null 2>&1 ;;
    sysv) /etc/init.d/sp-traffic status >/dev/null 2>&1 ;;
  esac
}

valid_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

config_uint() {
  local key="$1" fallback="$2" value
  value="$(awk -F= -v key="$key" '$1==key {print $2; exit}' "$CONFIG_FILE" 2>/dev/null)"
  value="${value%$'\r'}"
  if valid_uint "$value"; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

dashboard_refresh_seconds() {
  local seconds
  seconds="$(config_uint DASHBOARD_REFRESH_SECONDS "$DEFAULT_DASHBOARD_REFRESH_SECONDS")"
  if [ "$seconds" -gt "$MAX_DASHBOARD_REFRESH_SECONDS" ]; then
    seconds="$DEFAULT_DASHBOARD_REFRESH_SECONDS"
  fi
  printf '%s\n' "$seconds"
}

dashboard_auto_refresh_active() {
  local seconds
  seconds="$(dashboard_refresh_seconds)"
  [ "$seconds" -gt 0 ] || return 1
  service_is_active || return 1
  [ ! -f "$PAUSE_FILE" ]
}

available_disk_mb() {
  local disk_kb
  disk_kb="$(df -Pk "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  valid_uint "$disk_kb" || return 1
  printf '%s\n' "$((disk_kb / 1024))"
}

ensure_disk_headroom() {
  local minimum_mb available_mb
  minimum_mb="$(config_uint MIN_FREE_DISK_MB 200)"
  [ "$minimum_mb" -gt 0 ] || return 0
  available_mb="$(available_disk_mb)" || die "无法读取可用磁盘空间，已拒绝启动"
  [ "$available_mb" -ge "$minimum_mb" ] ||
    die "磁盘仅剩 ${available_mb} MiB，低于保护阈值 ${minimum_mb} MiB；请清理空间后重试"
}

valid_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

endpoint_count() {
  grep -Ec '^[[:space:]]*https?://' "$ENDPOINTS_FILE" 2>/dev/null || printf '0\n'
}

human_bytes() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ");
    i=1;
    while (b>=1024 && i<6) {b/=1024; i++}
    printf "%.2f %s", b, u[i]
  }'
}

sum_counter_prefix() {
  local prefix="$1"
  local total=0 file value
  for file in "${DATA_DIR}/counters/${prefix}"*; do
    [ -f "$file" ] || continue
    read -r value < "$file" || value=0
    value="${value%$'\r'}"
    valid_uint "$value" || value=0
    total=$((total + value))
  done
  printf '%s\n' "$total"
}

session_downloaded() {
  sum_counter_prefix 'download-session-worker-'
}

session_uploaded() {
  sum_counter_prefix 'upload-session-worker-'
}

read_live_stats() {
  local download_rate=0 upload_rate=0 active_download=0 active_upload=0 timestamp=0 now
  if [ -r "$LIVE_STATS_FILE" ]; then
    read -r download_rate upload_rate active_download active_upload timestamp < "$LIVE_STATS_FILE" || true
  fi
  valid_uint "$download_rate" || download_rate=0
  valid_uint "$upload_rate" || upload_rate=0
  valid_uint "$active_download" || active_download=0
  valid_uint "$active_upload" || active_upload=0
  valid_uint "$timestamp" || timestamp=0
  now="$(date +%s)"
  if [ "$timestamp" -eq 0 ] || [ $((now - timestamp)) -gt 5 ]; then
    download_rate=0
    upload_rate=0
    active_download=0
    active_upload=0
  fi
  printf '%s %s %s %s %s\n' \
    "$download_rate" "$upload_rate" "$active_download" "$active_upload" "$timestamp"
}

session_duration() {
  local started=0 now
  if [ -r "$SESSION_STARTED_FILE" ]; then
    read -r started < "$SESSION_STARTED_FILE" || started=0
  fi
  valid_uint "$started" || started=0
  now="$(date +%s)"
  if [ "$started" -eq 0 ] || [ "$now" -lt "$started" ]; then
    printf '0\n'
  else
    printf '%s\n' "$((now - started))"
  fi
}

format_duration() {
  local seconds="$1"
  valid_uint "$seconds" || seconds=0
  printf '%02d:%02d:%02d' \
    "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
}

format_rate() {
  local bytes_per_second="$1"
  awk -v value="$bytes_per_second" 'BEGIN {printf "%.1f Mbps", value * 8 / 1000000}'
}

read_last_session() {
  local download=0 upload=0 duration=0 saved_at=0
  if [ -r "$LAST_SESSION_FILE" ]; then
    read -r download upload duration saved_at < "$LAST_SESSION_FILE" || true
  fi
  valid_uint "$download" || download=0
  valid_uint "$upload" || upload=0
  valid_uint "$duration" || duration=0
  valid_uint "$saved_at" || saved_at=0
  printf '%s %s %s %s\n' "$download" "$upload" "$duration" "$saved_at"
}

read_last_exit() {
  local timestamp=0 status=0 failures=0 delay=0
  if [ -r "$LAST_EXIT_FILE" ]; then
    read -r timestamp status failures delay < "$LAST_EXIT_FILE" || true
  fi
  valid_uint "$timestamp" || timestamp=0
  valid_uint "$status" || status=0
  valid_uint "$failures" || failures=0
  valid_uint "$delay" || delay=0
  printf '%s %s %s %s\n' "$timestamp" "$status" "$failures" "$delay"
}

save_current_as_last() {
  local active_download active_upload
  local download upload duration now
  service_is_active || return 0
  read -r _ _ active_download active_upload _ <<<"$(read_live_stats)"
  download=$(( $(session_downloaded) + active_download ))
  upload=$(( $(session_uploaded) + active_upload ))
  duration="$(session_duration)"
  now="$(date +%s)"
  printf '%s %s %s %s\n' "$download" "$upload" "$duration" "$now" \
    >"${LAST_SESSION_FILE}.tmp"
  mv -f "${LAST_SESSION_FILE}.tmp" "$LAST_SESSION_FILE"
}

service_state_text() {
  local pause_reason=""
  if service_is_active; then
    if [ -f "$PAUSE_FILE" ]; then
      [ -r "$PAUSE_REASON_FILE" ] && read -r pause_reason < "$PAUSE_REASON_FILE"
      case "$pause_reason" in
        disk_low:*) printf '已暂停（低磁盘保护）\n' ;;
        manual) printf '已手动暂停\n' ;;
        *) printf '已暂停\n' ;;
      esac
    else
      printf '运行中\n'
    fi
  else
    printf '已停止\n'
  fi
}

show_status() {
  local state workers=0 qdisc cc available_mb minimum_mb aggressive_mode
  local download_rate upload_rate active_download active_upload
  local session_down session_up duration last_down last_up last_duration
  local exit_status restart_failures restart_delay refresh_seconds
  local is_active=0
  state="$(service_state_text)"
  service_is_active && is_active=1
  [ -r "${DATA_DIR}/effective_workers" ] && read -r workers < "${DATA_DIR}/effective_workers"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  read -r download_rate upload_rate active_download active_upload _ <<<"$(read_live_stats)"
  if [ "$is_active" -eq 0 ]; then
    download_rate=0
    upload_rate=0
    active_download=0
    active_upload=0
  fi
  session_down=$(( $(session_downloaded) + active_download ))
  session_up=$(( $(session_uploaded) + active_upload ))
  duration="$(session_duration)"
  if [ "$is_active" -eq 0 ]; then
    session_down=0
    session_up=0
    duration=0
  fi
  read -r last_down last_up last_duration _ <<<"$(read_last_session)"
  read -r _ exit_status restart_failures restart_delay <<<"$(read_last_exit)"
  available_mb="$(available_disk_mb 2>/dev/null || printf '未知')"
  minimum_mb="$(config_uint MIN_FREE_DISK_MB 200)"
  refresh_seconds="$(dashboard_refresh_seconds)"
  aggressive_mode="$(config_uint AGGRESSIVE_MODE 1)"
  if [ "$aggressive_mode" -eq 1 ]; then
    aggressive_mode="激进"
  else
    aggressive_mode="均衡"
  fi
  cat <<EOF
SP Traffic 状态
  服务:       ${state}
  有效并发:   ${workers}
  授权端点:   $(endpoint_count)
  实时下载:   $(format_rate "$download_rate")
  实时上传:   $(format_rate "$upload_rate")
  本次下载:   $(human_bytes "$session_down")
  本次上传:   $(human_bytes "$session_up")
  上次下载:   $(human_bytes "$last_down")
  上次上传:   $(human_bytes "$last_up")
  上次时长:   $(format_duration "$last_duration")
  运行时长:   $(format_duration "$duration")
  可用磁盘:   ${available_mb} MiB
  暂停阈值:   ${minimum_mb} MiB
  下载模式:   ${aggressive_mode}
  看板刷新:   ${refresh_seconds} 秒（0 为关闭）
  队列算法:   ${qdisc}
  拥塞控制:   ${cc}
  崩溃恢复:   连续 ${restart_failures} 次（最近退出码 ${exit_status}，退避 ${restart_delay} 秒）
EOF
}

ensure_endpoint() {
  [ "$(endpoint_count)" -gt 0 ] || die "请先用 '端点管理' 添加你拥有或获授权的下载 URL"
}

start_or_resume_command() {
  require_root "$@"
  ensure_endpoint
  ensure_disk_headroom
  if service_is_active; then
    if [ -f "$PAUSE_FILE" ]; then
      rm -f "$PAUSE_FILE" "$PAUSE_REASON_FILE"
      ok "服务已继续"
    else
      ok "服务已经在运行"
    fi
  else
    rm -f "$PAUSE_FILE" "$PAUSE_REASON_FILE"
    service_start
    ok "服务已启动；本次统计已重新开始，关闭 SSH 后仍会在后台运行"
  fi
}

pause_command() {
  require_root "$@"
  service_is_active || die "服务没有运行"
  printf 'manual\n' > "$PAUSE_REASON_FILE"
  touch "$PAUSE_FILE"
  local file pid
  for file in "${DATA_DIR}"/pids/curl-*.pid; do
    [ -f "$file" ] || continue
    read -r pid < "$file" || continue
    kill "$pid" 2>/dev/null || true
  done
  ok "服务已暂停"
}

resume_command() {
  start_or_resume_command "$@"
}

stop_command() {
  require_root "$@"
  service_stop
  rm -f "$PAUSE_FILE" "$PAUSE_REASON_FILE"
  ok "服务已停止"
}

clear_command() {
  require_root "$@"
  local file now was_active=0 was_paused=0
  if service_is_active; then
    was_active=1
    [ -f "$PAUSE_FILE" ] && was_paused=1
    service_stop
  fi
  mkdir -p "${DATA_DIR}/counters"
  for file in "${DATA_DIR}"/counters/*; do
    [ -f "$file" ] || continue
    printf '0\n' > "$file"
  done
  now="$(date +%s)"
  printf '%s\n' "$now" >"$SESSION_STARTED_FILE"
  : > "$RATE_HISTORY_FILE"
  rm -f "$LAST_SESSION_FILE" "${LAST_SESSION_FILE}.tmp"
  rm -f "$LAST_EXIT_FILE" "${LAST_EXIT_FILE}.tmp"
  rm -f "${DATA_DIR}"/size-*.tmp "${DATA_DIR}"/progress-*.tmp
  if [ "$was_active" -eq 1 ]; then
    if [ "$was_paused" -eq 1 ]; then
      printf 'manual\n' > "$PAUSE_REASON_FILE"
      touch "$PAUSE_FILE"
    fi
    service_start
  fi
  ok "临时文件、单次统计和历史上传/下载统计已清除（下载内容始终写入 /dev/null）"
}

list_endpoints() {
  local number=0 line
  echo "当前授权端点:"
  while IFS= read -r line || [ -n "$line" ]; do
    valid_url "$line" || continue
    number=$((number + 1))
    if [ "$line" = "$DEFAULT_ENDPOINT" ]; then
      printf '  %d) %s [默认：Hetzner 新加坡 10GB]\n' "$number" "$line"
    else
      printf '  %d) %s\n' "$number" "$line"
    fi
  done < "$ENDPOINTS_FILE"
  [ "$number" -gt 0 ] || echo "  （无）"
}

add_endpoint() {
  local url="${1:-}"
  if [ -z "$url" ]; then
    read -r -p "输入你拥有或已获明确授权的 HTTP/HTTPS 大文件 URL: " url
  fi
  valid_url "$url" || die "只允许 HTTP/HTTPS URL"
  grep -Fqx -- "$url" "$ENDPOINTS_FILE" 2>/dev/null || printf '%s\n' "$url" >> "$ENDPOINTS_FILE"
  chown root:sptraffic "$ENDPOINTS_FILE"
  chmod 0640 "$ENDPOINTS_FILE"
  service_is_active && service_restart
  ok "端点已添加"
}

add_default_endpoint() {
  add_endpoint "$DEFAULT_ENDPOINT"
  warn "这是第三方公共测速端点，仅建议短时测试；请确认流量费用和提供方规则"
}

remove_endpoint() {
  local target="${1:-}" temporary
  list_endpoints
  if [ -z "$target" ]; then
    read -r -p "输入要删除的完整 URL: " target
  fi
  temporary="$(mktemp)"
  grep -Fvx -- "$target" "$ENDPOINTS_FILE" > "$temporary" || true
  install -o root -g sptraffic -m 0640 "$temporary" "$ENDPOINTS_FILE"
  rm -f "$temporary"
  if service_is_active; then
    if [ "$(endpoint_count)" -gt 0 ]; then
      service_restart
    else
      service_stop
      warn "最后一个端点已删除，服务已停止"
    fi
  fi
  ok "端点已删除（如原列表中存在）"
}

set_config_value() {
  local key="$1" value="$2" temporary
  temporary="$(mktemp)"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN {done=0}
    $1==key {print key "=" value; done=1; next}
    {print}
    END {if (!done) print key "=" value}
  ' "$CONFIG_FILE" > "$temporary"
  install -o root -g sptraffic -m 0640 "$temporary" "$CONFIG_FILE"
  rm -f "$temporary"
}

configure_limits() {
  local workers max_mbps aggressive_mode current_mode
  read -r -p "并发数（0=自适应，1-32）: " workers
  valid_uint "$workers" || die "并发数必须是非负整数"
  [ "$workers" -le "$HARD_MAX_WORKERS" ] || die "最大并发为 ${HARD_MAX_WORKERS}"
  read -r -p "总下载限速 Mbps（0=不限速）: " max_mbps
  valid_uint "$max_mbps" || die "限速必须是非负整数"
  current_mode="$(config_uint AGGRESSIVE_MODE 1)"
  read -r -p "激进下载模式（1=激进，0=均衡，当前 ${current_mode}）: " aggressive_mode
  case "$aggressive_mode" in
    0|1) ;;
    *) die "下载模式只能是 0 或 1" ;;
  esac
  set_config_value WORKERS "$workers"
  set_config_value MAX_MBPS "$max_mbps"
  set_config_value AGGRESSIVE_MODE "$aggressive_mode"
  service_is_active && service_restart
  ok "配置已保存"
}

configure_refresh_interval() {
  local seconds="${1:-}" current
  current="$(dashboard_refresh_seconds)"
  if [ -z "$seconds" ]; then
    read -r -p \
      "看板刷新间隔秒（0=关闭，1-${MAX_DASHBOARD_REFRESH_SECONDS}，当前 ${current}）: " \
      seconds
  fi
  valid_uint "$seconds" || die "刷新间隔必须是非负整数"
  [ "$seconds" -le "$MAX_DASHBOARD_REFRESH_SECONDS" ] ||
    die "刷新间隔最大为 ${MAX_DASHBOARD_REFRESH_SECONDS} 秒"
  set_config_value DASHBOARD_REFRESH_SECONDS "$seconds"
  if [ "$seconds" -eq 0 ]; then
    ok "看板自动刷新已关闭；仍可按 R 手动刷新"
  else
    ok "看板将在程序运行时每 ${seconds} 秒刷新；暂停、停止或进入其他界面时不刷新"
  fi
}

endpoint_menu() {
  while :; do
    cat <<'EOF'

端点管理
  1) 查看
  2) 添加默认 Hetzner 新加坡 10GB
  3) 添加自定义端点
  4) 删除
  0) 返回
EOF
    read -r -p "请选择: " choice
    case "$choice" in
      1) list_endpoints ;;
      2) add_default_endpoint ;;
      3) add_endpoint ;;
      4) remove_endpoint ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

show_logs() {
  case "$(backend)" in
    systemd) journalctl -u sp-traffic.service -n 80 --no-pager ;;
    *) warn "当前服务后端不使用持久日志；运行状态请用 sp status 查看" ;;
  esac
}

restore_bbr() {
  rm -f /etc/sysctl.d/99-sp-traffic-bbr.conf /etc/modules-load.d/sp-traffic-bbr.conf
  if [ -r "${DATA_DIR}/bbr.previous" ]; then
    local key value
    while IFS='=' read -r key value; do
      [ -n "$value" ] || continue
      case "$key" in
        PREV_QDISC) sysctl -q -w "net.core.default_qdisc=${value}" 2>/dev/null || true ;;
        PREV_CC) sysctl -q -w "net.ipv4.tcp_congestion_control=${value}" 2>/dev/null || true ;;
        PREV_RMEM_MAX) sysctl -q -w "net.core.rmem_max=${value}" 2>/dev/null || true ;;
        PREV_WMEM_MAX) sysctl -q -w "net.core.wmem_max=${value}" 2>/dev/null || true ;;
        PREV_TCP_RMEM) sysctl -q -w "net.ipv4.tcp_rmem=${value}" 2>/dev/null || true ;;
        PREV_TCP_WMEM) sysctl -q -w "net.ipv4.tcp_wmem=${value}" 2>/dev/null || true ;;
        PREV_MTU_PROBING) sysctl -q -w "net.ipv4.tcp_mtu_probing=${value}" 2>/dev/null || true ;;
      esac
    done < "${DATA_DIR}/bbr.previous"
  fi
}

uninstall_command() {
  require_root "$@"
  local assume_yes="${1:-}" answer backend_name
  if [ "$assume_yes" != "--yes" ]; then
    read -r -p "确认卸载 SP Traffic 并删除其配置和统计？输入 YES: " answer
    [ "$answer" = "YES" ] || {
      warn "已取消"
      return
    }
  fi

  backend_name="$(backend)"
  service_stop 2>/dev/null || true
  case "$backend_name" in
    systemd)
      systemctl disable sp-traffic.service >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/sp-traffic.service
      systemctl daemon-reload
      ;;
    openrc)
      rc-update del sp-traffic default >/dev/null 2>&1 || true
      rm -f /etc/init.d/sp-traffic
      ;;
    sysv)
      if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d -f sp-traffic remove >/dev/null 2>&1 || true
      elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --del sp-traffic >/dev/null 2>&1 || true
      fi
      rm -f /etc/init.d/sp-traffic
      ;;
  esac
  restore_bbr
  rm -f /usr/local/bin/sp
  rm -rf -- "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
  if command -v userdel >/dev/null 2>&1; then
    userdel sptraffic 2>/dev/null || true
  elif command -v deluser >/dev/null 2>&1; then
    deluser sptraffic 2>/dev/null || true
  fi
  ok "SP Traffic 已卸载；项目创建的 BBR 配置已移除"
}

make_bar() {
  local value="$1" maximum="$2" width="$3" filled empty filled_text empty_text
  valid_uint "$value" || value=0
  valid_uint "$maximum" || maximum=1
  [ "$maximum" -ge 1 ] || maximum=1
  [ "$value" -le "$maximum" ] || value="$maximum"
  filled=$((value * width / maximum))
  empty=$((width - filled))
  printf -v filled_text '%*s' "$filled" ''
  printf -v empty_text '%*s' "$empty" ''
  filled_text="${filled_text// /█}"
  empty_text="${empty_text// /·}"
  printf '%s%s' "$filled_text" "$empty_text"
}

sparkline() {
  local column="$1" width="$2"
  tail -n "$width" "$RATE_HISTORY_FILE" 2>/dev/null |
    awk -v column="$column" -v width="$width" '
      {
        values[count++]=$column
        if ($column > maximum) maximum=$column
      }
      END {
        for (i=count; i<width; i++) printf " "
        for (i=0; i<count; i++) {
          if (maximum <= 0) {
            printf "."
          } else {
            level=int(values[i] * 8 / maximum)
            if (level > 8) level=8
            printf "%s", substr(".:-=+*#%@", level + 1, 1)
          }
        }
      }
    '
}

dashboard_line() {
  local row="$1" column="$2"
  shift 2
  printf '\033[%s;%sH%s' "$row" "$column" "$*"
}

load_dashboard_stats() {
  local is_active=0
  DASHBOARD_STATE="$(service_state_text)"
  service_is_active && is_active=1
  DASHBOARD_WORKERS=0
  [ -r "${DATA_DIR}/effective_workers" ] &&
    read -r DASHBOARD_WORKERS < "${DATA_DIR}/effective_workers"
  valid_uint "$DASHBOARD_WORKERS" || DASHBOARD_WORKERS=0

  read -r \
    DASHBOARD_DOWNLOAD_RATE \
    DASHBOARD_UPLOAD_RATE \
    DASHBOARD_ACTIVE_DOWNLOAD \
    DASHBOARD_ACTIVE_UPLOAD \
    _ <<<"$(read_live_stats)"
  if [ "$is_active" -eq 0 ]; then
    DASHBOARD_DOWNLOAD_RATE=0
    DASHBOARD_UPLOAD_RATE=0
    DASHBOARD_ACTIVE_DOWNLOAD=0
    DASHBOARD_ACTIVE_UPLOAD=0
  fi

  DASHBOARD_SESSION_DOWNLOAD=$(( $(session_downloaded) + DASHBOARD_ACTIVE_DOWNLOAD ))
  DASHBOARD_SESSION_UPLOAD=$(( $(session_uploaded) + DASHBOARD_ACTIVE_UPLOAD ))
  DASHBOARD_DURATION="$(session_duration)"
  if [ "$is_active" -eq 0 ]; then
    DASHBOARD_SESSION_DOWNLOAD=0
    DASHBOARD_SESSION_UPLOAD=0
    DASHBOARD_DURATION=0
  fi
  read -r \
    DASHBOARD_LAST_DOWNLOAD \
    DASHBOARD_LAST_UPLOAD \
    DASHBOARD_LAST_DURATION \
    _ <<<"$(read_last_session)"
  read -r _ _ DASHBOARD_RESTART_FAILURES _ <<<"$(read_last_exit)"
  DASHBOARD_DISK="$(available_disk_mb 2>/dev/null || printf '未知')"
  DASHBOARD_MODE="$(config_uint AGGRESSIVE_MODE 1)"
  if [ "$DASHBOARD_MODE" -eq 1 ]; then
    DASHBOARD_MODE="激进模式"
  else
    DASHBOARD_MODE="均衡模式"
  fi
  DASHBOARD_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
  DASHBOARD_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  DASHBOARD_REFRESH_SECONDS="$(dashboard_refresh_seconds)"
  if [ "$DASHBOARD_REFRESH_SECONDS" -eq 0 ]; then
    DASHBOARD_REFRESH_LABEL="关闭"
  elif [ "$is_active" -eq 0 ]; then
    DASHBOARD_REFRESH_LABEL="已停止"
  elif [ -f "$PAUSE_FILE" ]; then
    DASHBOARD_REFRESH_LABEL="已暂停"
  else
    DASHBOARD_REFRESH_LABEL="每 ${DASHBOARD_REFRESH_SECONDS} 秒"
  fi
}

render_dashboard_wide() {
  local refresh_mode="${1:-full}"
  local right_column=34 maximum_rate configured_mbps bar_down bar_up history_down history_up
  local line green cyan yellow reset state_color
  green=$'\033[1;32m'
  cyan=$'\033[1;36m'
  yellow=$'\033[1;33m'
  reset=$'\033[0m'

  configured_mbps="$(config_uint MAX_MBPS 0)"
  if [ "$configured_mbps" -gt 0 ]; then
    maximum_rate=$((configured_mbps * 125000))
  else
    maximum_rate=125000000
    [ "$DASHBOARD_DOWNLOAD_RATE" -le "$maximum_rate" ] ||
      maximum_rate="$DASHBOARD_DOWNLOAD_RATE"
    [ "$DASHBOARD_UPLOAD_RATE" -le "$maximum_rate" ] ||
      maximum_rate="$DASHBOARD_UPLOAD_RATE"
  fi
  bar_down="$(make_bar "$DASHBOARD_DOWNLOAD_RATE" "$maximum_rate" 22)"
  bar_up="$(make_bar "$DASHBOARD_UPLOAD_RATE" "$maximum_rate" 22)"
  history_down="$(sparkline 1 42)"
  history_up="$(sparkline 2 42)"
  case "$DASHBOARD_STATE" in
    运行中) state_color="$green" ;;
    已停止) state_color="$yellow" ;;
    *) state_color="$cyan" ;;
  esac

  if [ "$refresh_mode" = "inplace" ]; then
    printf '\033[H'
  else
    printf '\033[2J\033[H'
  fi
  dashboard_line 1 1 'SP Traffic'
  dashboard_line 2 1 '  1) 状态'
  dashboard_line 3 1 '  2) 开始/继续'
  dashboard_line 4 1 '  3) 暂停'
  dashboard_line 5 1 '  4) 停止'
  dashboard_line 6 1 '  5) 清除统计/临时文件'
  dashboard_line 7 1 '  6) 端点管理'
  dashboard_line 8 1 '  7) 并发与限速'
  dashboard_line 9 1 '  8) 最近日志'
  dashboard_line 10 1 '  9) 卸载'
  dashboard_line 11 1 '  T) 刷新间隔'
  dashboard_line 12 1 '  0) 退出'

  dashboard_line 1 "$right_column" '┌─ 实时流量监控 ─────────────────────────────────────────────────────────┐'
  printf -v line '│ %s↓ 下载%s  %-12s  %s[%s]%s' \
    "$green" "$reset" "$(format_rate "$DASHBOARD_DOWNLOAD_RATE")" \
    "$green" "$bar_down" "$reset"
  dashboard_line 2 "$right_column" "$line"
  printf -v line '│ %s↑ 上传%s  %-12s  %s[%s]%s' \
    "$cyan" "$reset" "$(format_rate "$DASHBOARD_UPLOAD_RATE")" \
    "$cyan" "$bar_up" "$reset"
  dashboard_line 3 "$right_column" "$line"
  dashboard_line 4 "$right_column" '├─ 流量统计 ─────────────────────────────────────────────────────────────┤'
  printf -v line '│ 本次运行   下载 %-11s   上传 %-11s' \
    "$(human_bytes "$DASHBOARD_SESSION_DOWNLOAD")" \
    "$(human_bytes "$DASHBOARD_SESSION_UPLOAD")"
  dashboard_line 5 "$right_column" "$line"
  printf -v line '│ 上次记录   下载 %-11s   上传 %-11s' \
    "$(human_bytes "$DASHBOARD_LAST_DOWNLOAD")" \
    "$(human_bytes "$DASHBOARD_LAST_UPLOAD")"
  dashboard_line 6 "$right_column" "$line"
  printf -v line '│ 本次时长 %-10s   上次时长 %-10s   连接数 %s / %s' \
    "$(format_duration "$DASHBOARD_DURATION")" \
    "$(format_duration "$DASHBOARD_LAST_DURATION")" \
    "$DASHBOARD_WORKERS" "$HARD_MAX_WORKERS"
  dashboard_line 7 "$right_column" "$line"
  printf -v line '│ 磁盘剩余 %-10s MiB   状态 %s%s%s   恢复 %s 次' \
    "$DASHBOARD_DISK" "$state_color" "$DASHBOARD_STATE" "$reset" \
    "$DASHBOARD_RESTART_FAILURES"
  dashboard_line 8 "$right_column" "$line"
  printf -v line '│ %s下载 60秒%s  %s%s%s' "$green" "$reset" "$green" "$history_down" "$reset"
  dashboard_line 9 "$right_column" "$line"
  printf -v line '│ %s上传 60秒%s  %s%s%s' "$cyan" "$reset" "$cyan" "$history_up" "$reset"
  dashboard_line 10 "$right_column" "$line"
  dashboard_line 11 "$right_column" '└──────────────────────────────────────────────────────────────────────────┘'

  printf -v line '%s[%s]%s %s | %s + %s | 自动并发 %s | 刷新 %s，R 手动，T 设置' \
    "$state_color" "$DASHBOARD_STATE" "$reset" \
    "$DASHBOARD_MODE" "$DASHBOARD_CC" "$DASHBOARD_QDISC" "$DASHBOARD_WORKERS" \
    "$DASHBOARD_REFRESH_LABEL"
  dashboard_line 14 1 "$line"
  dashboard_line 15 1 '请选择: '
  printf '\033[J'
}

render_dashboard_compact() {
  local refresh_mode="${1:-full}"
  local green cyan reset
  green=$'\033[1;32m'
  cyan=$'\033[1;36m'
  reset=$'\033[0m'
  if [ "$refresh_mode" = "inplace" ]; then
    printf '\033[H'
  else
    printf '\033[2J\033[H'
  fi
  cat <<'EOF'
SP Traffic
  1) 状态
  2) 开始/继续
  3) 暂停
  4) 停止
  5) 清除统计/临时文件
  6) 端点管理
  7) 并发与限速
  8) 最近日志
  9) 卸载
  T) 刷新间隔
  0) 退出
EOF
  printf '\n实时: %s↓ %s%s  %s↑ %s%s\n' \
    "$green" "$(format_rate "$DASHBOARD_DOWNLOAD_RATE")" "$reset" \
    "$cyan" "$(format_rate "$DASHBOARD_UPLOAD_RATE")" "$reset"
  printf '本次: 下载 %s  上传 %s\n' \
    "$(human_bytes "$DASHBOARD_SESSION_DOWNLOAD")" \
    "$(human_bytes "$DASHBOARD_SESSION_UPLOAD")"
  printf '上次: 下载 %s  上传 %s  时长 %s\n' \
    "$(human_bytes "$DASHBOARD_LAST_DOWNLOAD")" \
    "$(human_bytes "$DASHBOARD_LAST_UPLOAD")" \
    "$(format_duration "$DASHBOARD_LAST_DURATION")"
  printf '状态: %s  本次时长: %s  并发: %s/%s  恢复: %s 次\n' \
    "$DASHBOARD_STATE" "$(format_duration "$DASHBOARD_DURATION")" \
    "$DASHBOARD_WORKERS" "$HARD_MAX_WORKERS" "$DASHBOARD_RESTART_FAILURES"
  printf '刷新: %s（R 手动刷新，T 设置）\n' "$DASHBOARD_REFRESH_LABEL"
  printf '请选择: '
  printf '\033[J'
}

render_dashboard() {
  local refresh_mode="${1:-full}" columns
  load_dashboard_stats
  columns="$(tput cols 2>/dev/null || printf '80')"
  valid_uint "$columns" || columns=80
  if [ "$columns" -ge 112 ]; then
    render_dashboard_wide "$refresh_mode"
  else
    render_dashboard_compact "$refresh_mode"
  fi
}

wait_for_return() {
  [ -t 0 ] || return 0
  printf '\n按任意键返回菜单...'
  IFS= read -rsn1 _ || true
}

run_menu_action() {
  local choice="$1"
  printf '\033[2J\033[H'
  case "$choice" in
    1) show_status; wait_for_return ;;
    2) start_or_resume_command; wait_for_return ;;
    3) pause_command; wait_for_return ;;
    4) stop_command; wait_for_return ;;
    5) clear_command; wait_for_return ;;
    6) endpoint_menu ;;
    7) configure_limits; wait_for_return ;;
    8) show_logs; wait_for_return ;;
    9) uninstall_command; return 2 ;;
    t|T) configure_refresh_interval; wait_for_return ;;
    0) return 1 ;;
    r|R) ;;
    *) return 0 ;;
  esac
}

legacy_main_menu() {
  while :; do
    cat <<'EOF'

SP Traffic
  1) 状态
  2) 开始/继续
  3) 暂停
  4) 停止
  5) 清除统计/临时文件
  6) 端点管理
  7) 并发与限速
  8) 最近日志
  9) 卸载
  T) 刷新间隔
  0) 退出
EOF
    read -r -p "请选择: " choice
    case "$choice" in
      1) show_status ;;
      2) start_or_resume_command ;;
      3) pause_command ;;
      4) stop_command ;;
      5) clear_command ;;
      6) endpoint_menu ;;
      7) configure_limits ;;
      8) show_logs ;;
      9) uninstall_command; return ;;
      t|T) configure_refresh_interval ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

main_menu() {
  local choice action_status read_status refresh_seconds render_mode="full"
  if [ ! -t 0 ] || [ ! -t 1 ] || [ "${TERM:-dumb}" = "dumb" ]; then
    legacy_main_menu
    return
  fi

  while :; do
    render_dashboard "$render_mode"
    render_mode="inplace"
    choice=""
    if dashboard_auto_refresh_active; then
      refresh_seconds="$(dashboard_refresh_seconds)"
      IFS= read -rsn1 -t "$refresh_seconds" choice
      read_status=$?
      if [ "$read_status" -ne 0 ]; then
        if [ "$read_status" -gt 128 ]; then
          continue
        fi
        return
      fi
    elif ! IFS= read -rsn1 choice; then
      return
    fi
    run_menu_action "$choice"
    action_status=$?
    render_mode="full"
    case "$action_status" in
      1|2)
        printf '\033[2J\033[H'
        return
        ;;
    esac
  done
}

case "${1:-menu}" in
  -h|--help|help) ;;
  *) require_root "$@" ;;
esac

case "${1:-menu}" in
  menu) main_menu ;;
  dashboard) render_dashboard; printf '\n' ;;
  status) show_status ;;
  start) shift; start_or_resume_command "$@" ;;
  pause) shift; pause_command "$@" ;;
  resume|continue) shift; resume_command "$@" ;;
  stop) shift; stop_command "$@" ;;
  clear) shift; clear_command "$@" ;;
  endpoints)
    shift
    case "${1:-list}" in
      list) list_endpoints ;;
      default) shift; add_default_endpoint ;;
      add) require_root "$@"; shift; add_endpoint "${1:-}" ;;
      remove) require_root "$@"; shift; remove_endpoint "${1:-}" ;;
      *) die "用法: sp endpoints {list|default|add URL|remove URL}" ;;
    esac
    ;;
  configure) require_root "$@"; configure_limits ;;
  refresh) shift; configure_refresh_interval "${1:-}" ;;
  logs) show_logs ;;
  uninstall) shift; uninstall_command "$@" ;;
  -h|--help|help)
    cat <<'EOF'
用法: sp [dashboard|status|start|pause|resume|stop|clear|endpoints|configure|refresh|logs|uninstall]
端点: sp endpoints {list|default|add URL|remove URL}
刷新: sp refresh [秒数]（0=关闭，默认 10 秒）
不带参数时打开交互看板；运行中自动刷新，暂停/停止/其他界面不刷新，按 R 可手动刷新。
EOF
    ;;
  *) die "未知命令: $1（使用 sp --help 查看帮助）" ;;
esac
