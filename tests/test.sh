#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT_DIR}/install.sh"
bash -n "${ROOT_DIR}/sp"
bash -n "${ROOT_DIR}/worker.sh"
bash -n "${ROOT_DIR}/tests/stress.sh"

help_output="$("${ROOT_DIR}/sp" --help)"
grep -q 'start' <<<"$help_output"
grep -q 'dashboard' <<<"$help_output"
grep -q 'uninstall' <<<"$help_output"
grep -q 'endpoints {list|default' <<<"$help_output"

install_help="$(bash "${ROOT_DIR}/install.sh" --help)"
grep -q -- '--url' <<<"$install_help"
grep -q -- '--max-mbps' <<<"$install_help"
grep -q -- '--balanced' <<<"$install_help"
grep -q -- '--start' <<<"$install_help"

default_endpoint='https://sin-speed.hetzner.com/10GB.bin'
grep -Fq "$default_endpoint" "${ROOT_DIR}/install.sh"
grep -Fq "$default_endpoint" "${ROOT_DIR}/sp"
grep -Fq "$default_endpoint" "${ROOT_DIR}/README.md"
grep -Fq 'MIN_FREE_DISK_MB=200' "${ROOT_DIR}/install.sh"
grep -Fq 'AGGRESSIVE_MODE=1' "${ROOT_DIR}/install.sh"
grep -Fq 'for candidate in bbrz bbr3 bbr2 bbr' "${ROOT_DIR}/install.sh"
grep -Fq 'HARD_MAX_WORKERS=32' "${ROOT_DIR}/worker.sh"
grep -Fq 'enforce_disk_guard' "${ROOT_DIR}/worker.sh"
grep -Fq 'update_live_stats' "${ROOT_DIR}/worker.sh"
grep -Fq '%{size_download} %{size_upload}' "${ROOT_DIR}/worker.sh"
grep -Fq 'download-session-worker-' "${ROOT_DIR}/worker.sh"
grep -Fq 'RATE_HISTORY_TRIM_THRESHOLD=90' "${ROOT_DIR}/worker.sh"
grep -Fq 'MAX_TRANSFER_TIMEOUT=1800' "${ROOT_DIR}/worker.sh"
grep -Fq 'cleanup_stale_runtime_files' "${ROOT_DIR}/worker.sh"
grep -Fq 'supervise_worker_process' "${ROOT_DIR}/worker.sh"
grep -Fq 'terminate_worker_group' "${ROOT_DIR}/worker.sh"
grep -Fq 'RUN_STATE_FILE=' "${ROOT_DIR}/worker.sh"
grep -Fq 'LAST_EXIT_FILE=' "${ROOT_DIR}/worker.sh"
grep -Fq 'StandardOutput=null' "${ROOT_DIR}/install.sh"
grep -Fq 'StandardError=null' "${ROOT_DIR}/install.sh"
grep -Fq 'ensure_disk_headroom' "${ROOT_DIR}/sp"
grep -Fq '2) 开始/继续' "${ROOT_DIR}/sp"
grep -Fq '本次运行' "${ROOT_DIR}/sp"
grep -Fq '上次记录' "${ROOT_DIR}/sp"
grep -Fq 'save_current_as_last' "${ROOT_DIR}/sp"
if grep -Fq '历史总计' "${ROOT_DIR}/sp"; then
  echo "历史总计 should no longer appear in the dashboard" >&2
  exit 1
fi
if grep -Fq 'read -rsn1 -t' "${ROOT_DIR}/sp"; then
  echo "interactive dashboard should not redraw on a read timeout" >&2
  exit 1
fi

workers_error="$(bash "${ROOT_DIR}/install.sh" --workers 33 2>&1 || true)"
grep -q -- '--workers 最大为 32' <<<"$workers_error"

if bash "${ROOT_DIR}/install.sh" --url ftp://example.com/file >/dev/null 2>&1; then
  echo "expected non-HTTP endpoint to fail" >&2
  exit 1
fi

echo "All tests passed."
