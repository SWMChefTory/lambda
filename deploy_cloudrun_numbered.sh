#!/usr/bin/env bash
set -euo pipefail

REGION="asia-northeast3"
MAP="cookies_out/cookie_map.jsonl"

PROJECT_ID="$(gcloud config get-value core/project)"
: "${PROJECT_ID:?need gcloud project}"

APP_IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/services/lambda-migrated:latest"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need gcloud
need jq

# Cloud Run이 Secret 읽을 수 있도록 권한(기본 compute SA)
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" >/dev/null 2>&1 || true

# function 중복 제거 + 정렬(항상 같은 번호가 나오게)
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

jq -r '[.function,.region,.secret] | @tsv' "$MAP" \
| sort -u \
| sort -k2,2 -k1,1 \
> "$tmp"

out="deploy_map.tsv"
: > "$out"
echo -e "num\tregion\tfunction\tsecret\turl" >> "$out"

i=0
while IFS=$'\t' read -r fn region secret; do
  i=$((i+1))
  svc="captionlambda-$i"
  echo "== Deploy #$i $region/$fn -> $svc (secret=$secret) =="

  gcloud run deploy "$svc" \
    --image "$APP_IMAGE" \
    --region "$REGION" \
    --platform managed \
    --allow-unauthenticated \
    --memory 512Mi \
    --cpu 1 \
    --timeout 60 \
    --set-secrets "/var/task/assets/yt_cookies/cookies.txt=${secret}:latest" \
    --set-env-vars "YTDLP_COOKIES=/var/task/assets/yt_cookies/cookies.txt" \
    >/dev/null

  url="$(gcloud run services describe "$svc" --region "$REGION" --format='value(status.url)')"
  echo -e "$i\t$region\t$fn\t$secret\t$url" >> "$out"
  echo "  URL: $url"
done < "$tmp"

echo ""
echo "DONE"
echo "Mapping saved to: $out"
