#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 IPA_PATH" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

IPA_PATH="$1"
[[ -f "$IPA_PATH" ]] || { echo "IPA not found: $IPA_PATH" >&2; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "codesign is required to verify unsigned status" >&2; exit 1; }

if /usr/bin/unzip -Z1 "$IPA_PATH" | LC_ALL=C grep -Eq '(^|/)_CodeSignature(/|$)'; then
  echo "IPA contains a forbidden _CodeSignature entry" >&2
  exit 1
fi

EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-unsigned-ipa.XXXXXX")"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
/usr/bin/unzip -q "$IPA_PATH" -d "$EXTRACT_DIR"

signature_dir="$(find "$EXTRACT_DIR" -type d -name _CodeSignature -print -quit)"
[[ -z "$signature_dir" ]] || { echo "IPA contains a forbidden signature directory: $signature_dir" >&2; exit 1; }

APP_COUNT="$(find "$EXTRACT_DIR/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$APP_COUNT" == "1" ]] || { echo "Payload must contain exactly one .app (found $APP_COUNT)" >&2; exit 1; }
APP_PATH="$(find "$EXTRACT_DIR/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -f "$APP_PATH/Info.plist" ]] || { echo "Packaged app has no Info.plist" >&2; exit 1; }

set +e
CODESIGN_OUTPUT="$(LC_ALL=C /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1)"
CODESIGN_STATUS=$?
set -e
if [[ "$CODESIGN_STATUS" -eq 0 ]]; then
  echo "codesign accepted the app; expected an unsigned bundle" >&2
  exit 1
fi
if [[ "$CODESIGN_OUTPUT" != *"code object is not signed at all"* ]]; then
  echo "codesign did not report a deterministically unsigned bundle:" >&2
  echo "$CODESIGN_OUTPUT" >&2
  exit 1
fi

echo "Verified unsigned IPA: no _CodeSignature entries and codesign reports unsigned."
