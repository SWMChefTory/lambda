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

# Cloud Run -> Secret 접근 권한(기본 compute SA에 부여)
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" >/dev/null 2>&1 || true

norm() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-63
}

tmp_seen="$(mktemp)"
trap 'rm -f "$tmp_seen"' EXIT
: > "$tmp_seen"

while IFS= read -r line; do
  fn="$(echo "$line" | jq -r '.function')"
  secret="$(echo "$line" | jq -r '.secret')"

  if grep -qx "$fn" "$tmp_seen"; then
    continue
  fi
  echo "$fn" >> "$tmp_seen"

  svc="$(norm "$fn")"
  echo "== Deploy $fn -> service=$svc, secret=$secret =="

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
  echo "  URL: $url"
done < "$MAP"

echo "DONE"
