#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"  # DRY_RUN=1 이면 실제 삭제/연결변경 안 함(로그만)
doit() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY] $*"
  else
    eval "$@"
  fi
}

regions=$(aws ec2 describe-regions --all-regions --query 'Regions[].RegionName' --output text)

for region in $regions; do
  echo "=== REGION: $region ==="

  # 1) region 내 VPC들의 DHCP 옵션을 default로 되돌려서(=분리) 삭제 가능 상태로 만들기
  vpcs=$(aws ec2 describe-vpcs --region "$region" --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)
  if [ -n "${vpcs:-}" ]; then
    for vpc in $vpcs; do
      dhcp=$(aws ec2 describe-vpcs --region "$region" --vpc-ids "$vpc" \
        --query 'Vpcs[0].DhcpOptionsId' --output text 2>/dev/null || true)

      # default(또는 공백)면 스킵
      if [ -n "${dhcp:-}" ] && [ "$dhcp" != "default" ] && [ "$dhcp" != "None" ]; then
        echo "  vpc=$vpc dhcp=$dhcp -> associate default"
        doit "aws ec2 associate-dhcp-options --region \"$region\" --vpc-id \"$vpc\" --dhcp-options-id default >/dev/null"
      fi
    done
  fi

  # 2) default가 아닌 DHCP 옵션 세트 삭제
  dhcps=$(aws ec2 describe-dhcp-options --region "$region" \
    --query 'DhcpOptions[?DhcpOptionsId!=`default`].DhcpOptionsId' --output text 2>/dev/null || true)

  if [ -z "${dhcps:-}" ]; then
    echo "  no custom dhcp-options"
    continue
  fi

  for dhcp in $dhcps; do
    echo "  delete dhcp-options: $dhcp"
    doit "aws ec2 delete-dhcp-options --region \"$region\" --dhcp-options-id \"$dhcp\" >/dev/null"
  done
done

echo "ALL DONE (DRY_RUN=$DRY_RUN)"
