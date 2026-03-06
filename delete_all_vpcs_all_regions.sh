#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}" # 1이면 출력만, 0이면 실제 삭제
doit() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY] $*"
  else
    echo "[RUN] $*"
    eval "$@"
  fi
}

regions=$(aws ec2 describe-regions --all-regions --query 'Regions[].RegionName' --output text)

for region in $regions; do
  echo "=============================="
  echo "REGION: $region"
  echo "=============================="

  vpcs=$(aws ec2 describe-vpcs --region "$region" --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)
  [ -n "${vpcs:-}" ] || { echo "no vpcs"; continue; }

  for vpc in $vpcs; do
    echo "---- VPC: $vpc ----"

    # IGW detach/delete
    igws=$(aws ec2 describe-internet-gateways --region "$region" \
      --filters "Name=attachment.vpc-id,Values=$vpc" \
      --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)
    if [ -n "${igws:-}" ]; then
      for igw in $igws; do
        doit "aws ec2 detach-internet-gateway --region $region --internet-gateway-id $igw --vpc-id $vpc >/dev/null"
        doit "aws ec2 delete-internet-gateway --region $region --internet-gateway-id $igw >/dev/null"
      done
    fi

    # subnets delete
    subnets=$(aws ec2 describe-subnets --region "$region" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)
    if [ -n "${subnets:-}" ]; then
      for sn in $subnets; do
        doit "aws ec2 delete-subnet --region $region --subnet-id $sn >/dev/null"
      done
    fi

    # SG delete (except default)
    sgs=$(aws ec2 describe-security-groups --region "$region" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)
    if [ -n "${sgs:-}" ]; then
      for sg in $sgs; do
        doit "aws ec2 delete-security-group --region $region --group-id $sg >/dev/null"
      done
    fi

    # delete vpc
    doit "aws ec2 delete-vpc --region $region --vpc-id $vpc >/dev/null"
    echo "done: $vpc"
  done
done

echo "ALL DONE (DRY_RUN=$DRY_RUN)"
