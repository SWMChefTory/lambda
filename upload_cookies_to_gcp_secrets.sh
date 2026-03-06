#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value core/project)"
: "${PROJECT_ID:?need gcloud project}"

ROOT="cookies_out"

# secret 이름에 쓸 수 없는 문자 정리: 대문자->소문자, 언더스코어/점 제거
norm() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

for region_dir in "$ROOT"/*; do
  [ -d "$region_dir" ] || continue
  region="$(basename "$region_dir")"

  for fn_dir in "$region_dir"/*; do
    [ -d "$fn_dir" ] || continue
    fn="$(basename "$fn_dir")"

    cookie_file="$fn_dir/assets/yt_cookies/cookies.txt"
    if [ ! -f "$cookie_file" ]; then
      echo "skip (no cookies): $region/$fn"
      continue
    fi

    secret_name="$(norm "ytdlp-cookies-$region-$fn")"
    echo "== $region / $fn -> $secret_name =="

    # 이미 있으면 create는 실패하니 무시하고 계속
    gcloud secrets create "$secret_name" --replication-policy="automatic" >/dev/null 2>&1 || true
    gcloud secrets versions add "$secret_name" --data-file="$cookie_file" >/dev/null

    echo "  uploaded: $cookie_file"
  done
done

echo "DONE"
