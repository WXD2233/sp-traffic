#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ "$PYTHON_BIN" == *.exe ]] \
  || ! "$PYTHON_BIN" -c 'import os, pty, select, subprocess, termios' 2>/dev/null; then
  echo "Dashboard refresh PTY test skipped: POSIX Python PTY is unavailable."
  exit 0
fi

TEST_DIR="$(mktemp -d)"
cleanup() {
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p \
  "$TEST_DIR/bin" \
  "$TEST_DIR/config" \
  "$TEST_DIR/data/counters" \
  "$TEST_DIR/data/pids"

cat >"$TEST_DIR/config/config" <<'EOF'
WORKERS=1
MAX_MBPS=0
AGGRESSIVE_MODE=1
DASHBOARD_REFRESH_SECONDS=1
MIN_FREE_DISK_MB=0
EOF
printf 'systemd\n' >"$TEST_DIR/config/backend"
printf 'https://example.test/authorized.bin\n' >"$TEST_DIR/config/endpoints"
printf '0 0 0 0 0\n' >"$TEST_DIR/data/live_stats"
: >"$TEST_DIR/data/rate_history"

cat >"$TEST_DIR/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
EOF
cat >"$TEST_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  is-active) [ "${MOCK_ACTIVE:-1}" = "1" ] ;;
  *) exit 0 ;;
esac
EOF
cat >"$TEST_DIR/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
printf 'mock\n'
EOF
cat >"$TEST_DIR/bin/tput" <<'EOF'
#!/usr/bin/env bash
printf '80\n'
EOF
chmod 0755 "$TEST_DIR"/bin/*

SP_PATH="$ROOT_DIR/sp" \
SP_CONFIG_DIR="$TEST_DIR/config" \
SP_DATA_DIR="$TEST_DIR/data" \
SP_TEST_PATH="$TEST_DIR/bin:$PATH" \
  "$PYTHON_BIN" <<'PY'
import os
import pty
import select
import subprocess
import time

sp_path = os.environ["SP_PATH"]
data_dir = os.environ["SP_DATA_DIR"]
base_env = os.environ.copy()
base_env["PATH"] = os.environ["SP_TEST_PATH"]
base_env["TERM"] = "xterm"


def collect(master: int, duration: float) -> bytes:
    output = bytearray()
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
    return bytes(output)


def start_menu(env: dict[str, str]) -> tuple[subprocess.Popen, int]:
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [sp_path],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)
    return process, master


def stop_menu(process: subprocess.Popen, master: int) -> None:
    os.write(master, b"0")
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=3)
    os.close(master)


def run_menu(active: bool, paused: bool, wait_seconds: float) -> bytes:
    pause_path = os.path.join(data_dir, "paused")
    if paused:
        open(pause_path, "wb").close()
    elif os.path.exists(pause_path):
        os.unlink(pause_path)

    env = base_env.copy()
    env["MOCK_ACTIVE"] = "1" if active else "0"
    process, master = start_menu(env)
    output = collect(master, wait_seconds)
    stop_menu(process, master)
    return output


running = run_menu(active=True, paused=False, wait_seconds=3.2)
running_frames = running.count(b"SP Traffic\r\n")
if running_frames < 3:
    raise SystemExit(
        f"expected at least three running dashboard frames, got {running_frames}"
    )

paused = run_menu(active=True, paused=True, wait_seconds=2.2)
paused_frames = paused.count(b"SP Traffic\r\n")
if paused_frames != 1:
    raise SystemExit(
        f"paused dashboard should render once without a timer, got {paused_frames}"
    )

stopped = run_menu(active=False, paused=False, wait_seconds=2.2)
stopped_frames = stopped.count(b"SP Traffic\r\n")
if stopped_frames != 1:
    raise SystemExit(
        f"stopped dashboard should render once without a timer, got {stopped_frames}"
    )

status_env = base_env.copy()
status_env["MOCK_ACTIVE"] = "1"
status_process, status_master = start_menu(status_env)
status_output = bytearray(collect(status_master, 0.4))
os.write(status_master, b"1")
status_output.extend(collect(status_master, 2.2))
status_frames = bytes(status_output).count(b"SP Traffic\r\n")
if status_frames != 1:
    raise SystemExit(
        f"status screen should suspend dashboard refresh, got {status_frames} frames"
    )
os.write(status_master, b"x")
collect(status_master, 0.4)
stop_menu(status_process, status_master)

print(
    "Dashboard refresh test passed: running auto-refreshes; paused, stopped, and other screens stay static."
)
PY
