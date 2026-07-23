#!/usr/bin/env bash
set -uo pipefail

readonly INSTALL_DIR="${SP_INSTALL_DIR:-/opt/sp-traffic}"
readonly CONFIG_DIR="${SP_CONFIG_DIR:-/etc/sp-traffic}"
readonly DATA_DIR="${SP_DATA_DIR:-/var/lib/sp-traffic}"
readonly CONFIG_FILE="${CONFIG_DIR}/config"
readonly ENDPOINTS_FILE="${CONFIG_DIR}/endpoints"
readonly BACKEND_FILE="${CONFIG_DIR}/backend"
readonly PAUSE_FILE="${DATA_DIR}/paused"
readonly HARD_MAX_WORKERS=16
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
  case "$(backend)" in
    systemd) systemctl stop sp-traffic.service ;;
    openrc) rc-service sp-traffic stop ;;
    sysv) /etc/init.d/sp-traffic stop ;;
  esac
}

service_restart() {
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

total_downloaded() {
  local total=0 file value
  for file in "${DATA_DIR}"/counters/worker-*; do
    [ -f "$file" ] || continue
    read -r value < "$file" || value=0
    valid_uint "$value" || value=0
    total=$((total + value))
  done
  printf '%s\n' "$total"
}

show_status() {
  local state workers=0 qdisc cc total
  if service_is_active; then
    if [ -f "$PAUSE_FILE" ]; then state="已暂停"; else state="运行中"; fi
  else
    state="已停止"
  fi
  [ -r "${DATA_DIR}/effective_workers" ] && read -r workers < "${DATA_DIR}/effective_workers"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  total="$(total_downloaded)"
  cat <<EOF
SP Traffic 状态
  服务:       ${state}
  有效并发:   ${workers}
  授权端点:   $(endpoint_count)
  已完成下载: $(human_bytes "$total")
  队列算法:   ${qdisc}
  拥塞控制:   ${cc}
EOF
}

ensure_endpoint() {
  [ "$(endpoint_count)" -gt 0 ] || die "请先用 '端点管理' 添加你拥有或获授权的下载 URL"
}

start_command() {
  require_root "$@"
  ensure_endpoint
  rm -f "$PAUSE_FILE"
  service_start
  ok "服务已启动；关闭 SSH 后仍会在后台运行"
}

pause_command() {
  require_root "$@"
  service_is_active || die "服务没有运行"
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
  require_root "$@"
  ensure_endpoint
  rm -f "$PAUSE_FILE"
  if service_is_active; then
    ok "服务已继续"
  else
    service_start
    ok "服务已重新启动并继续"
  fi
}

stop_command() {
  require_root "$@"
  service_stop
  rm -f "$PAUSE_FILE"
  ok "服务已停止"
}

clear_command() {
  require_root "$@"
  local file
  mkdir -p "${DATA_DIR}/counters"
  for file in "${DATA_DIR}"/counters/worker-*; do
    [ -f "$file" ] || continue
    printf '0\n' > "$file"
  done
  rm -f "${DATA_DIR}"/size-*.tmp
  ok "临时文件和下载统计已清除（下载内容始终直接写入 /dev/null）"
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
  local workers max_mbps
  read -r -p "并发数（0=自适应，1-16）: " workers
  valid_uint "$workers" || die "并发数必须是非负整数"
  [ "$workers" -le "$HARD_MAX_WORKERS" ] || die "最大并发为 ${HARD_MAX_WORKERS}"
  read -r -p "总下载限速 Mbps（0=不限速）: " max_mbps
  valid_uint "$max_mbps" || die "限速必须是非负整数"
  set_config_value WORKERS "$workers"
  set_config_value MAX_MBPS "$max_mbps"
  service_is_active && service_restart
  ok "配置已保存"
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

main_menu() {
  while :; do
    cat <<'EOF'

SP Traffic
  1) 状态
  2) 开始
  3) 暂停
  4) 继续
  5) 停止
  6) 清除统计/临时文件
  7) 端点管理
  8) 并发与限速
  9) 最近日志
 10) 卸载
  0) 退出
EOF
    read -r -p "请选择: " choice
    case "$choice" in
      1) show_status ;;
      2) start_command ;;
      3) pause_command ;;
      4) resume_command ;;
      5) stop_command ;;
      6) clear_command ;;
      7) endpoint_menu ;;
      8) require_root; configure_limits ;;
      9) show_logs ;;
      10) uninstall_command; return ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

case "${1:-menu}" in
  -h|--help|help) ;;
  *) require_root "$@" ;;
esac

case "${1:-menu}" in
  menu) main_menu ;;
  status) show_status ;;
  start) shift; start_command "$@" ;;
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
  logs) show_logs ;;
  uninstall) shift; uninstall_command "$@" ;;
  -h|--help|help)
    cat <<'EOF'
用法: sp [status|start|pause|resume|stop|clear|endpoints|configure|logs|uninstall]
端点: sp endpoints {list|default|add URL|remove URL}
不带参数时打开交互菜单。
EOF
    ;;
  *) die "未知命令: $1（使用 sp --help 查看帮助）" ;;
esac
