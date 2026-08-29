#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run-simulator-tests.sh --udid UDID [options]

Options:
  --udid UDID              simulator device identifier (required)
  --project PATH           Xcode project (default: TVerClient.xcodeproj)
  --scheme NAME            scheme (default: TVerClient)
  --derived-data PATH      DerivedData directory
  --log-dir PATH           diagnostic output directory
  --timeout-seconds N      timeout per boot/test command (default: 900)
  --attempts N             maximum test attempts (default: 3)
  -h, --help               show this help
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMEOUT_RUNNER="$SCRIPT_DIR/run-with-timeout.sh"
UDID=""
PROJECT="$REPO_ROOT/TVerClient.xcodeproj"
SCHEME="TVerClient"
DERIVED_DATA="${TMPDIR:-/tmp}/TVerClient-SimulatorDerivedData"
LOG_DIR="${TMPDIR:-/tmp}/TVerClient-simulator-logs"
TIMEOUT_SECONDS=900
ATTEMPTS=3

while (($#)); do
  case "$1" in
    --udid) UDID="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --scheme) SCHEME="${2:-}"; shift 2 ;;
    --derived-data) DERIVED_DATA="${2:-}"; shift 2 ;;
    --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --attempts) ATTEMPTS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$UDID" ]] || { echo "--udid is required" >&2; exit 2; }
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid timeout: $TIMEOUT_SECONDS" >&2; exit 2; }
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid attempts: $ATTEMPTS" >&2; exit 2; }
if [[ "$PROJECT" != /* ]]; then PROJECT="$REPO_ROOT/$PROJECT"; fi
[[ -d "$PROJECT" ]] || { echo "Xcode project not found: $PROJECT" >&2; exit 1; }
[[ -x "$TIMEOUT_RUNNER" ]] || { echo "Timeout runner not executable: $TIMEOUT_RUNNER" >&2; exit 1; }
mkdir -p "$DERIVED_DATA" "$LOG_DIR"

collect_diagnostics() {
  local attempt="$1"
  xcrun simctl list devices > "$LOG_DIR/simctl-devices-attempt-${attempt}.txt" 2>&1 || true
  "$TIMEOUT_RUNNER" 30 xcrun simctl spawn "$UDID" log show \
    --last 10m --style compact \
    --predicate 'process == "TVerClient" OR process == "xctest"' \
    > "$LOG_DIR/simulator-attempt-${attempt}.log" 2>&1 || true
}

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
  echo "::group::Simulator test attempt ${attempt}/${ATTEMPTS}"
  result_bundle="$LOG_DIR/simulator-tests-attempt-${attempt}.xcresult"
  test_log="$LOG_DIR/simulator-tests-attempt-${attempt}.log"
  rm -rf "$result_bundle"

  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  if ((attempt > 1)); then
    xcrun simctl erase "$UDID" >/dev/null 2>&1 || true
  fi
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true

  set +e
  "$TIMEOUT_RUNNER" 120 xcrun simctl bootstatus "$UDID" -b 2>&1 | tee "$LOG_DIR/simulator-boot-attempt-${attempt}.log"
  boot_status=${PIPESTATUS[0]}
  set -e

  test_status="$boot_status"
  if [[ "$boot_status" -eq 0 ]]; then
    set +e
    NSUnbufferedIO=YES "$TIMEOUT_RUNNER" "$TIMEOUT_SECONDS" \
      xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$DERIVED_DATA" \
      -resultBundlePath "$result_bundle" \
      test 2>&1 | tee "$test_log"
    test_status=${PIPESTATUS[0]}
    set -e
  else
    echo "Simulator failed to boot (exit $boot_status)" | tee "$test_log"
  fi

  if [[ "$test_status" -eq 0 ]]; then
    echo "Simulator tests passed on attempt $attempt."
    echo "::endgroup::"
    exit 0
  fi

  echo "Simulator test attempt $attempt failed with exit $test_status." >&2
  collect_diagnostics "$attempt"
  tail -n 200 "$test_log" >&2 || true
  echo "::endgroup::"
done

echo "Simulator tests failed after $ATTEMPTS attempts. Diagnostics: $LOG_DIR" >&2
exit 1
