#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 TIMEOUT_SECONDS COMMAND [ARG ...]" >&2
  exit 2
fi

timeout_seconds="$1"
shift

python3 - "$timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)


def terminate_group(signum=None, _frame=None):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


signal.signal(signal.SIGTERM, terminate_group)
signal.signal(signal.SIGINT, terminate_group)

try:
    exit_code = process.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    print(
        f"Command timed out after {seconds}s: {' '.join(command)}",
        file=sys.stderr,
        flush=True,
    )
    terminate_group()
    sys.exit(124)

sys.exit(exit_code)
PY
