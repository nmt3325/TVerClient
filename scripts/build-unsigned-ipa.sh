#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-unsigned-ipa.sh [options]

Build TVerClient for a generic iOS device without code signing and package it
as an unsigned IPA.

Options:
  -d, --derived-data PATH  xcodebuild DerivedData directory
  -o, --output PATH        output IPA path
      --project PATH       Xcode project path (default: TVerClient.xcodeproj)
      --scheme NAME        scheme name (default: TVerClient)
      --timeout-seconds N   xcodebuild timeout (default: 1200)
      --log-dir PATH        build log/result bundle directory
      --                   pass remaining arguments to xcodebuild
  -h, --help               show this help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="${TMPDIR:-/tmp}/TVerClient-DerivedData"
OUTPUT="$REPO_ROOT/TVerClient-unsigned.ipa"
PROJECT="$REPO_ROOT/TVerClient.xcodeproj"
SCHEME="TVerClient"
TIMEOUT_SECONDS=1200
LOG_DIR=""
TIMEOUT_RUNNER="$SCRIPT_DIR/run-with-timeout.sh"

while (($#)); do
  case "$1" in
    -d|--derived-data)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      DERIVED_DATA="$2"
      shift 2
      ;;
    -o|--output)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      PROJECT="$2"
      shift 2
      ;;
    --scheme)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      SCHEME="$2"
      shift 2
      ;;
    --timeout-seconds)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --log-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      LOG_DIR="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid timeout: $TIMEOUT_SECONDS" >&2; exit 2; }
[[ -x "$TIMEOUT_RUNNER" ]] || { echo "Timeout runner not executable: $TIMEOUT_RUNNER" >&2; exit 1; }
mkdir -p "$DERIVED_DATA" "$(dirname "$OUTPUT")"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"
if [[ -z "$LOG_DIR" ]]; then LOG_DIR="$DERIVED_DATA/logs"; fi
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
BUILD_LOG="$LOG_DIR/unsigned-ipa-build.log"
RESULT_BUNDLE="$LOG_DIR/unsigned-ipa-build.xcresult"
rm -rf "$RESULT_BUNDLE"

if [[ "$PROJECT" != /* ]]; then
  PROJECT="$REPO_ROOT/$PROJECT"
fi
[[ -d "$PROJECT" ]] || { echo "Xcode project not found: $PROJECT" >&2; exit 1; }

set +e
NSUnbufferedIO=YES "$TIMEOUT_RUNNER" "$TIMEOUT_SECONDS" \
  xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  "$@" \
  build 2>&1 | tee "$BUILD_LOG"
build_status=${PIPESTATUS[0]}
set -e
if [[ "$build_status" -ne 0 ]]; then
  echo "Unsigned IPA build failed with exit $build_status. Log: $BUILD_LOG" >&2
  tail -n 200 "$BUILD_LOG" >&2 || true
  exit "$build_status"
fi

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/${SCHEME}.app"
[[ -d "$APP_PATH" ]] || { echo "Built app not found: $APP_PATH" >&2; exit 1; }
[[ -f "$APP_PATH/Info.plist" ]] || { echo "Built app has no Info.plist" >&2; exit 1; }

EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist")"
[[ -f "$APP_PATH/$EXECUTABLE" ]] || { echo "Built app has no executable: $EXECUTABLE" >&2; exit 1; }

STAGING_DIR="$(mktemp -d "$DERIVED_DATA/unsigned-ipa.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/Payload"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Payload/${SCHEME}.app"
rm -rf "$STAGING_DIR/Payload/${SCHEME}.app/_CodeSignature"

APP_COUNT="$(find "$STAGING_DIR/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$APP_COUNT" == "1" ]] || { echo "Payload must contain exactly one .app (found $APP_COUNT)" >&2; exit 1; }

rm -f "$OUTPUT"
(
  cd "$STAGING_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$OUTPUT"
)

/usr/bin/unzip -tq "$OUTPUT" >/dev/null
/usr/bin/unzip -Z1 "$OUTPUT" | grep -qx "Payload/${SCHEME}.app/Info.plist" || {
  echo "IPA does not contain Payload/${SCHEME}.app/Info.plist" >&2
  exit 1
}

CHECKSUM="$OUTPUT.sha256"
(
  cd "$(dirname "$OUTPUT")"
  shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$CHECKSUM")"
)

echo "Unsigned IPA: $OUTPUT"
echo "SHA-256: $CHECKSUM"
