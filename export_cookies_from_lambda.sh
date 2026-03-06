#!/usr/bin/env bash
set -euo pipefail

# ====== 설정 ======
REGIONS=(
  ap-northeast-2
  ap-northeast-1
  ap-southeast-1
  us-west-2
  us-east-1
)

# env 없을 때 기본으로 찾을 쿠키 경로 (너가 말한 공통 경로)
DEFAULT_COOKIES_PATH="/var/task/assets/yt_cookies/cookies.txt"

OUT_DIR="${OUT_DIR:-cookies_out}"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need aws
need jq
need unzip
need curl

to_relpath() {
  local p="$1"
  p="${p#/var/task/}"
  p="${p#/opt/}"
  echo "$p"
}

extract_from_zip() {
  local zip="$1"
  local rel="$2"
  local dest_dir="$3"

  local candidates=(
    "$rel"
    "app/$rel"
    "python/$rel"
    "opt/$rel"
    "python/lib/python3.12/site-packages/$rel"
    "python/lib/python3.11/site-packages/$rel"
    "python/lib/python3.10/site-packages/$rel"
    "python/lib/python3.9/site-packages/$rel"
  )

  for c in "${candidates[@]}"; do
    if unzip -l "$zip" "$c" >/dev/null 2>&1; then
      mkdir -p "$dest_dir/$(dirname "$rel")"
      unzip -o -j "$zip" "$c" -d "$dest_dir/$(dirname "$rel")" >/dev/null
      local fname
      fname="$(basename "$rel")"
      # -j 때문에 파일명만 떨어지니 목표명으로 맞춤
      if [ -f "$dest_dir/$(dirname "$rel")/$(basename "$c")" ] && [ "$(basename "$c")" != "$fname" ]; then
        mv -f "$dest_dir/$(dirname "$rel")/$(basename "$c")" "$dest_dir/$(dirname "$rel")/$fname"
      fi
      chmod 600 "$dest_dir/$rel" 2>/dev/null || true
      echo "FOUND:$c"
      return 0
    fi
  done

  return 1
}

download_url_to() {
  local url="$1"
  local out="$2"
  curl -fsSL "$url" -o "$out"
}

download_function_code_zip() {
  local region="$1"
  local fn="$2"
  local out_zip="$3"

  local code_url
  code_url="$(aws lambda get-function --region "$region" --function-name "$fn" \
    --query 'Code.Location' --output text)"

  download_url_to "$code_url" "$out_zip"
}

download_layer_zip() {
  local region="$1"
  local layer_arn="$2"
  local out_zip="$3"

  local layer_url
  layer_url="$(aws lambda get-layer-version-by-arn --region "$region" --arn "$layer_arn" \
    --query 'Content.Location' --output text)"

  download_url_to "$layer_url" "$out_zip"
}

manifest="$OUT_DIR/manifest.jsonl"
: > "$manifest"

for region in "${REGIONS[@]}"; do
  echo "== REGION: $region =="

  fns="$(aws lambda list-functions --region "$region" --query 'Functions[].FunctionName' --output text || true)"
  if [ -z "${fns:-}" ]; then
    echo "  (no functions)"
    continue
  fi

  for fn in $fns; do
    # env에 YTDLP_COOKIES가 있으면 그걸 쓰고, 없으면 기본 경로로 강제
    cookies_path="$(aws lambda get-function-configuration --region "$region" --function-name "$fn" \
      --query 'Environment.Variables.YTDLP_COOKIES' --output text 2>/dev/null || true)"
    if [ -z "${cookies_path:-}" ] || [ "$cookies_path" = "None" ]; then
      cookies_path="$DEFAULT_COOKIES_PATH"
    fi

    rel="$(to_relpath "$cookies_path")"
    dest="$OUT_DIR/$region/$fn"
    mkdir -p "$dest"
    chmod 700 "$dest"

    echo "-> $fn (cookies_path=$cookies_path)"

    found=""
    fn_zip="$TMP_DIR/$region-$fn-code.zip"
    if download_function_code_zip "$region" "$fn" "$fn_zip" 2>/dev/null; then
      if extract_from_zip "$fn_zip" "$rel" "$dest" >/dev/null 2>&1; then
        found="function_code"
      fi
    fi

    if [ -z "$found" ]; then
      layer_arns="$(aws lambda get-function-configuration --region "$region" --function-name "$fn" \
        --query 'Layers[].Arn' --output text 2>/dev/null || true)"

      for layer_arn in $layer_arns; do
        layer_zip="$TMP_DIR/$region-$fn-$(echo "$layer_arn" | tr ':/' '__').zip"
        if download_layer_zip "$region" "$layer_arn" "$layer_zip" 2>/dev/null; then
          if extract_from_zip "$layer_zip" "$rel" "$dest" >/dev/null 2>&1; then
            found="layer:$layer_arn"
            break
          fi
        fi
      done
    fi

    if [ -z "$found" ]; then
      echo "   !! NOT FOUND: $cookies_path"
    else
      echo "   ✅ extracted ($found) -> $dest/$rel"
    fi

    jq -nc --arg region "$region" --arg fn "$fn" --arg cookies "$cookies_path" --arg found "${found:-}" \
      '{region:$region,function:$fn,ytdlp_cookies:$cookies,found_in:$found}' >> "$manifest"
  done
done

echo ""
echo "DONE. Output: $OUT_DIR"
echo "Manifest: $manifest"
