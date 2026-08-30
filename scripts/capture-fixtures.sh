#!/usr/bin/env bash
#
# Captures raw TVer responses so the committed synthetic fixtures can be checked
# against the real shapes by hand.
#
# Output goes to TVerClientTests/Fixtures/Captured/, which is gitignored: raw
# upstream payloads must never be committed to this public repository. Copy the
# structure into a fixture and replace every value with a placeholder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/TVerClientTests/Fixtures/Captured"
mkdir -p "$OUT"

BASE='https://platform-api.tver.jp/service/api/v1'

capture() {
  local name="$1" url="$2"
  curl -fsS \
    -H 'x-tver-platform-type: web' \
    -H 'Referer: https://tver.jp/' \
    -H 'Accept: application/json' \
    "$url" > "$OUT/$name.captured.json"
  echo "captured $name"
}

creds="$(curl -fsS -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Referer: https://s.tver.jp/' \
  --data 'device_type=pc' \
  'https://platform-api.tver.jp/v2/api/platform_users/browser/create')"

uid="$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["platform_uid"])')"
token="$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["platform_token"])')"
auth="platform_uid=$uid&platform_token=$token"

capture platform_episode_ranking "$BASE/callEpisodeRanking?$auth"
capture platform_ranking "$BASE/callRanking?$auth"
capture platform_live_channel "$BASE/callLiveChannel?$auth"

channel="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d.get("result",{}).get("contents",[]); print(c[0]["content"]["id"] if c else "")' "$OUT/platform_live_channel.captured.json")"
if [ -n "$channel" ]; then
  capture platform_live_timeline "$BASE/callLiveTimeline/$channel?$auth"
  capture platform_series_episodes "$BASE/callSeriesEpisodes/PLACEHOLDER_SERIES_ID?$auth" || echo 'skipped series episodes: set a real series id first'
fi

echo
echo "Raw captures are in $OUT (gitignored)."
echo 'Never commit them. Mirror only the structure into TVerClientTests/Fixtures/*.json.'
