#!/usr/bin/env bash
set -euo pipefail

ROOT="cookies_out"
MAP_OUT="$ROOT/cookie_map.jsonl"
SKIP_IF_EXISTS="${SKIP_IF_EXISTS:-1}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need gcloud
need shasum
need jq

files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
  find "$ROOT" -path '*/assets/yt_cookies/cookies.txt' -type f -print0
)

tmp_hash_list="$(mktemp)"
tmp_unique="$(mktemp)"
: > "$tmp_hash_list"

for f in "${files[@]}"; do
  h="$(shasum -a 256 "$f" | awk '{print $1}')"
  echo "$h|$f" >> "$tmp_hash_list"
done

sort "$tmp_hash_list" | awk -F'|' '!seen[$1]++{print $0}' > "$tmp_unique"

: > "$MAP_OUT"
i=0

while IFS='|' read -r hash file; do
  i=$((i+1))
  secret_name="ytdlp-cookies-$i"

  # secret 존재 보장(없으면 생성 + 업로드)
  if ! gcloud secrets describe "$secret_name" >/dev/null 2>&1; then
    echo "create missing secret: $secret_name"
    gcloud secrets create "$secret_name" --replication-policy="automatic" >/dev/null
    gcloud secrets versions add "$secret_name" --data-file="$file" >/dev/null
  else
    # 스킵 모드면 업로드 안 함
    if [ "$SKIP_IF_EXISTS" != "1" ]; then
      gcloud secrets versions add "$secret_name" --data-file="$file" >/dev/null
    fi
  fi

  # mapping 기록
  while IFS='|' read -r h2 f2; do
    [ "$h2" = "$hash" ] || continue
    region="$(echo "$f2" | awk -F'/' '{print $2}')"
    fn="$(echo "$f2" | awk -F'/' '{print $3}')"
    jq -nc --arg region "$region" --arg fn "$fn" --arg secret "$secret_name" --arg hash "$hash" \
      '{region:$region,function:$fn,secret:$secret,hash:$hash}' >> "$MAP_OUT"
  done < "$tmp_hash_list"

done < "$tmp_unique"

rm -f "$tmp_hash_list" "$tmp_unique"
echo "DONE: mapping -> $MAP_OUT"
