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
XCODEBUILD_ARGS=()

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
    --)
      shift
      XCODEBUILD_ARGS=("$@")
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

mkdir -p "$DERIVED_DATA" "$(dirname "$OUTPUT")"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"

if [[ "$PROJECT" != /* ]]; then
  PROJECT="$REPO_ROOT/$PROJECT"
fi
[[ -d "$PROJECT" ]] || { echo "Xcode project not found: $PROJECT" >&2; exit 1; }

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  "${XCODEBUILD_ARGS[@]}" \
  build

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

echo "Unsigned IPA: $OUTPUT"
