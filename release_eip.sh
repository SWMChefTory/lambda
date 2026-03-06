#!/usr/bin/env bash
set -euo pipefail

region="${1:-ap-northeast-2}"

aws ec2 describe-addresses --region "$region" \
  --query 'Addresses[].{AllocationId:AllocationId,AssociationId:AssociationId,PublicIp:PublicIp}' \
  --output json \
| jq -r '.[] | @tsv' \
| while IFS=$'\t' read -r alloc assoc ip; do
    echo "EIP ip=$ip alloc=$alloc assoc=$assoc"

    # 1) 붙어있으면 분리
    if [[ "${assoc}" != "null" && -n "${assoc}" ]]; then
      aws ec2 disassociate-address --region "$region" --association-id "$assoc" || true
    fi

    # 2) 할당 해제
    if [[ "${alloc}" != "null" && -n "${alloc}" ]]; then
      aws ec2 release-address --region "$region" --allocation-id "$alloc" || true
    elif [[ "${ip}" != "null" && -n "${ip}" ]]; then
      aws ec2 release-address --region "$region" --public-ip "$ip" || true
    fi
  done
