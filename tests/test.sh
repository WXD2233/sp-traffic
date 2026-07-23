#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT_DIR}/install.sh"
bash -n "${ROOT_DIR}/sp"
bash -n "${ROOT_DIR}/worker.sh"

help_output="$("${ROOT_DIR}/sp" --help)"
grep -q 'start' <<<"$help_output"
grep -q 'uninstall' <<<"$help_output"
grep -q 'endpoints {list|default' <<<"$help_output"

install_help="$(bash "${ROOT_DIR}/install.sh" --help)"
grep -q -- '--url' <<<"$install_help"
grep -q -- '--max-mbps' <<<"$install_help"
grep -q -- '--start' <<<"$install_help"

default_endpoint='https://sin-speed.hetzner.com/10GB.bin'
grep -Fq "$default_endpoint" "${ROOT_DIR}/install.sh"
grep -Fq "$default_endpoint" "${ROOT_DIR}/sp"
grep -Fq "$default_endpoint" "${ROOT_DIR}/README.md"

if bash "${ROOT_DIR}/install.sh" --workers 17 >/dev/null 2>&1; then
  echo "expected --workers 17 to fail" >&2
  exit 1
fi

if bash "${ROOT_DIR}/install.sh" --url ftp://example.com/file >/dev/null 2>&1; then
  echo "expected non-HTTP endpoint to fail" >&2
  exit 1
fi

echo "All tests passed."
