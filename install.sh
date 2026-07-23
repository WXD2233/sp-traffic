#!/usr/bin/env bash
set -Eeuo pipefail

readonly SP_VERSION="1.3.0"
readonly SP_REPOSITORY="${SP_REPOSITORY:-WXD2233/sp-traffic}"
readonly SP_BRANCH="${SP_BRANCH:-main}"
readonly SP_RAW_BASE="${SP_RAW_BASE:-https://raw.githubusercontent.com/${SP_REPOSITORY}/${SP_BRANCH}}"
readonly SP_INSTALL_DIR="${SP_INSTALL_DIR:-/opt/sp-traffic}"
readonly SP_CONFIG_DIR="${SP_CONFIG_DIR:-/etc/sp-traffic}"
readonly SP_DATA_DIR="${SP_DATA_DIR:-/var/lib/sp-traffic}"
readonly SP_BIN_PATH="${SP_BIN_PATH:-/usr/local/bin/sp}"
readonly DEFAULT_ENDPOINT="${SP_DEFAULT_ENDPOINT:-https://sin-speed.hetzner.com/10GB.bin}"

URLS=()
WORKERS="0"
MAX_MBPS="0"
AGGRESSIVE_MODE="1"
ENABLE_BBR="1"
AUTO_START="1"
START_DEFAULT="0"
TEMPORARY_DIR=""

info() {
  printf '\033[1;34m[sp]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[sp]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[sp]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法:
  curl -fsSL INSTALL_URL | sudo bash
  curl -fsSL INSTALL_URL | sudo bash -s -- --url https://example.com/large.bin

选项:
  --url URL          添加一个经授权的 HTTP/HTTPS 下载端点，可重复使用
  --workers N        并发数；0 表示根据 CPU、内存和磁盘自动调整（默认）
  --max-mbps N       总下载限速，单位 Mbps；0 表示不主动限速（默认）
  --balanced         使用均衡下载模式；默认启用激进下载模式
  --start             使用内置默认端点，安装后立即启动
  --no-bbr           不配置 BBR + FQ
  --no-start         安装后不自动启动
  -h, --help         显示帮助
EOF
}

validate_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url)
      [ "$#" -ge 2 ] || die "--url 缺少参数"
      validate_url "$2" || die "只允许 HTTP/HTTPS 端点: $2"
      URLS+=("$2")
      shift 2
      ;;
    --workers)
      [ "$#" -ge 2 ] || die "--workers 缺少参数"
      validate_uint "$2" || die "--workers 必须是非负整数"
      [ "$2" -le 32 ] || die "--workers 最大为 32"
      WORKERS="$2"
      shift 2
      ;;
    --max-mbps)
      [ "$#" -ge 2 ] || die "--max-mbps 缺少参数"
      validate_uint "$2" || die "--max-mbps 必须是非负整数"
      MAX_MBPS="$2"
      shift 2
      ;;
    --no-bbr)
      ENABLE_BBR="0"
      shift
      ;;
    --balanced)
      AGGRESSIVE_MODE="0"
      shift
      ;;
    --start)
      AUTO_START="1"
      START_DEFAULT="1"
      shift
      ;;
    --no-start)
      AUTO_START="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "安装需要 root 权限，请使用: curl ... | sudo bash"
[ "$(uname -s)" = "Linux" ] || die "目前只支持 Linux"

install_dependencies() {
  local packages=(bash curl ca-certificates)
  if command -v apt-get >/dev/null 2>&1; then
    info "检测到 Debian/Ubuntu，安装运行依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${packages[@]}" kmod procps
  elif command -v dnf >/dev/null 2>&1; then
    info "检测到 Fedora/RHEL 系，安装运行依赖"
    dnf install -y "${packages[@]}" kmod procps-ng
  elif command -v yum >/dev/null 2>&1; then
    info "检测到 CentOS/RHEL 系，安装运行依赖"
    yum install -y "${packages[@]}" kmod procps-ng
  elif command -v apk >/dev/null 2>&1; then
    info "检测到 Alpine，安装运行依赖"
    apk add --no-cache "${packages[@]}" kmod procps
  elif command -v pacman >/dev/null 2>&1; then
    info "检测到 Arch，安装运行依赖"
    pacman -Sy --noconfirm --needed "${packages[@]}" kmod procps-ng
  elif command -v zypper >/dev/null 2>&1; then
    info "检测到 openSUSE，安装运行依赖"
    zypper --non-interactive install "${packages[@]}" kmod procps
  else
    command -v bash >/dev/null 2>&1 || die "缺少 bash，且无法识别包管理器"
    command -v curl >/dev/null 2>&1 || die "缺少 curl，且无法识别包管理器"
    warn "无法识别包管理器，将使用系统已有依赖"
  fi
}

fetch_file() {
  local name="$1"
  local destination="$2"
  if [ -n "${SP_SOURCE_DIR:-}" ] && [ -f "${SP_SOURCE_DIR}/${name}" ]; then
    install -m 0755 "${SP_SOURCE_DIR}/${name}" "$destination"
  else
    curl --fail --silent --show-error --location \
      --connect-timeout 15 --max-time 120 \
      "${SP_RAW_BASE}/${name}" -o "$destination"
    chmod 0755 "$destination"
  fi
}

create_service_user() {
  if id sptraffic >/dev/null 2>&1; then
    return
  fi
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --home-dir "$SP_DATA_DIR" --shell /usr/sbin/nologin sptraffic 2>/dev/null ||
      useradd -r -d "$SP_DATA_DIR" -s /sbin/nologin sptraffic
  elif command -v adduser >/dev/null 2>&1; then
    adduser -S -D -H -h "$SP_DATA_DIR" -s /sbin/nologin sptraffic
  else
    die "无法创建低权限运行用户 sptraffic"
  fi
}

write_config() {
  install -d -m 0750 "$SP_CONFIG_DIR"
  chown root:sptraffic "$SP_CONFIG_DIR"
  if [ ! -f "${SP_CONFIG_DIR}/config" ]; then
    cat >"${SP_CONFIG_DIR}/config" <<EOF
# 0 = 根据 CPU、可用内存和可用磁盘自动调整；最大并发硬限制为 32
WORKERS=${WORKERS}
# 总下载限速（Mbps）；0 = 不主动限速
MAX_MBPS=${MAX_MBPS}
# 1 = 激进下载（更多并发和更快重试）；0 = 均衡下载
AGGRESSIVE_MODE=${AGGRESSIVE_MODE}
# 可用磁盘低于该值时立即终止传输并自动暂停；0 = 禁用
MIN_FREE_DISK_MB=200
CONNECT_TIMEOUT=15
TRANSFER_TIMEOUT=900
CYCLE_DELAY=2
EOF
  fi
  if ! grep -Eq '^MIN_FREE_DISK_MB=[0-9]+$' "${SP_CONFIG_DIR}/config"; then
    printf '\n# 可用磁盘低于该值时立即终止传输并自动暂停；0 = 禁用\nMIN_FREE_DISK_MB=200\n' \
      >>"${SP_CONFIG_DIR}/config"
  fi
  if ! grep -Eq '^AGGRESSIVE_MODE=[01]$' "${SP_CONFIG_DIR}/config"; then
    printf '\n# 1 = 激进下载（更多并发和更快重试）；0 = 均衡下载\nAGGRESSIVE_MODE=1\n' \
      >>"${SP_CONFIG_DIR}/config"
  fi

  touch "${SP_CONFIG_DIR}/endpoints"
  if [ "${#URLS[@]}" -gt 0 ]; then
    : >"${SP_CONFIG_DIR}/endpoints"
    local url
    for url in "${URLS[@]}"; do
      printf '%s\n' "$url" >>"${SP_CONFIG_DIR}/endpoints"
    done
  elif ! grep -Eq '^[[:space:]]*https?://' "${SP_CONFIG_DIR}/endpoints"; then
    printf '%s\n' "$DEFAULT_ENDPOINT" >"${SP_CONFIG_DIR}/endpoints"
  fi
  chown root:sptraffic "${SP_CONFIG_DIR}/config" "${SP_CONFIG_DIR}/endpoints"
  chmod 0640 "${SP_CONFIG_DIR}/config" "${SP_CONFIG_DIR}/endpoints"
}

configure_bbr() {
  [ "$ENABLE_BBR" = "1" ] || return 0
  command -v sysctl >/dev/null 2>&1 || {
    warn "系统没有 sysctl，已跳过 BBR 配置"
    return 0
  }

  install -d -m 0755 /etc/sysctl.d
  install -d -m 0755 /etc/modules-load.d

  touch "${SP_DATA_DIR}/bbr.previous"
  if ! grep -q '^PREV_QDISC=' "${SP_DATA_DIR}/bbr.previous"; then
    printf 'PREV_QDISC=%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" \
      >>"${SP_DATA_DIR}/bbr.previous"
  fi
  if ! grep -q '^PREV_CC=' "${SP_DATA_DIR}/bbr.previous"; then
    printf 'PREV_CC=%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" \
      >>"${SP_DATA_DIR}/bbr.previous"
  fi
  if ! grep -q '^PREV_RMEM_MAX=' "${SP_DATA_DIR}/bbr.previous"; then
    printf 'PREV_RMEM_MAX=%s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || true)" \
      >>"${SP_DATA_DIR}/bbr.previous"
  fi
  if ! grep -q '^PREV_WMEM_MAX=' "${SP_DATA_DIR}/bbr.previous"; then
    printf 'PREV_WMEM_MAX=%s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || true)" \
      >>"${SP_DATA_DIR}/bbr.previous"
  fi
  if ! grep -q '^PREV_TCP_RMEM=' "${SP_DATA_DIR}/bbr.previous"; then
    printf 'PREV_TCP_RMEM=%s\n' "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true)" \
      >>"${SP_DATA_DIR}/bbr.previous"
  fi
  if ! grep -q '^PREV_TCP_WMEM=' "${SP_DATA_DIR}/bbr.previous"; then
    printf 'PREV_TCP_WMEM=%s\n' "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true)" \
      >>"${SP_DATA_DIR}/bbr.previous"
  fi
  if ! grep -q '^PREV_MTU_PROBING=' "${SP_DATA_DIR}/bbr.previous"; then
    printf 'PREV_MTU_PROBING=%s\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true)" \
      >>"${SP_DATA_DIR}/bbr.previous"
  fi
  chown root:root "${SP_DATA_DIR}/bbr.previous"
  chmod 0600 "${SP_DATA_DIR}/bbr.previous"

  modprobe tcp_bbrz 2>/dev/null || true
  modprobe tcp_bbr3 2>/dev/null || true
  modprobe tcp_bbr2 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || true
  local available selected="" module="" candidate
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  for candidate in bbrz bbr3 bbr2 bbr; do
    case " ${available} " in
      *" ${candidate} "*)
        selected="$candidate"
        break
        ;;
    esac
  done

  case "$selected" in
    bbrz)
      if [ -d /sys/module/tcp_bbrz ]; then module="tcp_bbrz"; fi
      ;;
    bbr3)
      if [ -d /sys/module/tcp_bbr3 ]; then
        module="tcp_bbr3"
      elif [ -d /sys/module/tcp_bbr ]; then
        module="tcp_bbr"
      fi
      ;;
    bbr2)
      if [ -d /sys/module/tcp_bbr2 ]; then
        module="tcp_bbr2"
      elif [ -d /sys/module/tcp_bbr ]; then
        module="tcp_bbr"
      fi
      ;;
    bbr)
      if [ -d /sys/module/tcp_bbr ]; then module="tcp_bbr"; fi
      ;;
  esac
  if [ -n "$module" ]; then
    printf '%s\n' "$module" > /etc/modules-load.d/sp-traffic-bbr.conf
  else
    rm -f /etc/modules-load.d/sp-traffic-bbr.conf
  fi

  cat > /etc/sysctl.d/99-sp-traffic-bbr.conf <<'EOF'
# Managed by sp-traffic
net.core.default_qdisc=fq
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 1048576 33554432
net.ipv4.tcp_wmem=4096 1048576 33554432
net.ipv4.tcp_mtu_probing=1
EOF
  if [ -n "$selected" ]; then
    printf 'net.ipv4.tcp_congestion_control=%s\n' "$selected" \
      >> /etc/sysctl.d/99-sp-traffic-bbr.conf
  fi

  if sysctl -q -p /etc/sysctl.d/99-sp-traffic-bbr.conf 2>/dev/null; then
    if [ -n "$selected" ]; then
      info "${selected} + FQ 与大 TCP 缓冲已启用"
    else
      warn "当前内核没有 BBRZ/BBR3/BBR2/BBR，已保留原拥塞控制并启用 FQ/缓冲调优"
    fi
  else
    warn "部分网络调优未能应用；未自动替换内核或重启"
  fi
}

install_systemd_service() {
  cat > /etc/systemd/system/sp-traffic.service <<EOF
[Unit]
Description=SP authorized bandwidth saturation service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sptraffic
Group=sptraffic
WorkingDirectory=${SP_DATA_DIR}
ExecStart=${SP_INSTALL_DIR}/worker.sh
Restart=always
RestartSec=3
Nice=5
OOMScoreAdjust=500
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  printf 'systemd\n' >"${SP_CONFIG_DIR}/backend"
  systemctl daemon-reload
  systemctl enable sp-traffic.service >/dev/null
}

install_openrc_service() {
  cat > /etc/init.d/sp-traffic <<EOF
#!/sbin/openrc-run
name="sp-traffic"
description="SP authorized bandwidth saturation service"
command="${SP_INSTALL_DIR}/worker.sh"
command_user="sptraffic:sptraffic"
command_background="yes"
pidfile="${SP_DATA_DIR}/service.pid"
output_log="/dev/null"
error_log="/dev/null"

depend() {
  need net
  after firewall
}
EOF
  chmod 0755 /etc/init.d/sp-traffic
  printf 'openrc\n' >"${SP_CONFIG_DIR}/backend"
  rc-update add sp-traffic default >/dev/null 2>&1 || true
}

install_sysv_service() {
  cat > /etc/init.d/sp-traffic <<EOF
#!/usr/bin/env bash
### BEGIN INIT INFO
# Provides:          sp-traffic
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: SP authorized bandwidth saturation service
### END INIT INFO
set -u
PIDFILE=${SP_DATA_DIR}/service.pid
DAEMON=${SP_INSTALL_DIR}/worker.sh
case "\${1:-}" in
  start)
    [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null && exit 0
    if command -v start-stop-daemon >/dev/null 2>&1; then
      start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" \
        --chuid sptraffic --startas "\$DAEMON"
    else
      su -s /bin/bash sptraffic -c "nohup \$DAEMON >/dev/null 2>&1 & echo \\\$! >\$PIDFILE"
    fi
    ;;
  stop)
    if [ -f "\$PIDFILE" ]; then
      kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
      rm -f "\$PIDFILE"
    fi
    ;;
  restart) "\$0" stop; "\$0" start ;;
  status) [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
  chmod 0755 /etc/init.d/sp-traffic
  printf 'sysv\n' >"${SP_CONFIG_DIR}/backend"
  if command -v update-rc.d >/dev/null 2>&1; then
    update-rc.d sp-traffic defaults >/dev/null
  elif command -v chkconfig >/dev/null 2>&1; then
    chkconfig --add sp-traffic
  fi
}

install_service() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    install_systemd_service
  elif command -v rc-service >/dev/null 2>&1; then
    install_openrc_service
  else
    warn "未检测到 systemd/OpenRC，将使用 SysV 兼容服务"
    install_sysv_service
  fi
}

start_if_ready() {
  [ "$AUTO_START" = "1" ] || return 0
  if [ "${#URLS[@]}" -eq 0 ] && [ "$START_DEFAULT" != "1" ]; then
    warn "已配置默认 Hetzner 新加坡 10GB 测速端点，服务保持停止"
    warn "确认流量费用和使用规则后，运行 sudo sp start；安装时可用 --start 明确启动"
    return 0
  fi
  if ! grep -Eq '^[[:space:]]*https?://' "${SP_CONFIG_DIR}/endpoints"; then
    warn "尚未配置下载端点，服务保持停止；运行 sudo sp 后添加经授权端点"
    return 0
  fi

  case "$(cat "${SP_CONFIG_DIR}/backend")" in
    systemd) systemctl restart sp-traffic.service ;;
    openrc) rc-service sp-traffic restart ;;
    sysv) /etc/init.d/sp-traffic restart ;;
  esac
}

main() {
  install_dependencies
  create_service_user
  install -d -m 0755 "$SP_INSTALL_DIR"
  install -d -m 0750 -o sptraffic -g sptraffic "$SP_DATA_DIR"
  install -d -m 0750 -o sptraffic -g sptraffic "${SP_DATA_DIR}/counters" "${SP_DATA_DIR}/pids"
  write_config

  TEMPORARY_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TEMPORARY_DIR"' EXIT
  fetch_file "sp" "${TEMPORARY_DIR}/sp"
  fetch_file "worker.sh" "${TEMPORARY_DIR}/worker.sh"
  install -m 0755 "${TEMPORARY_DIR}/sp" "${SP_INSTALL_DIR}/sp"
  install -m 0755 "${TEMPORARY_DIR}/worker.sh" "${SP_INSTALL_DIR}/worker.sh"
  ln -sfn "${SP_INSTALL_DIR}/sp" "$SP_BIN_PATH"

  install_service
  configure_bbr
  start_if_ready

  info "安装完成（v${SP_VERSION}）"
  info "管理命令: sudo sp"
  info "默认端点: ${DEFAULT_ENDPOINT}"
  info "仅可使用你拥有或已获明确授权的下载端点。"
}

main "$@"
