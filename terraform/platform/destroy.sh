#!/usr/bin/env bash
# Safe teardown. ALBs and EBS volumes are created by controllers *inside* the
# cluster, so Terraform doesn't know about them. Delete them through Kubernetes
# first, or `terraform destroy` hangs on the VPC and you keep paying for orphans.
set -euo pipefail

echo "==> Stopping ArgoCD from recreating apps"
kubectl delete applications.argoproj.io --all -n argocd --ignore-not-found --wait=false || true

echo "==> Deleting Ingresses (controller removes the ALBs)"
kubectl delete ingress --all -A --ignore-not-found

echo "==> Deleting app namespace (StatefulSets + PVCs -> EBS volumes deleted)"
kubectl delete namespace tenderflow --ignore-not-found

echo "==> Waiting 90s for AWS to finish deleting ALBs and volumes"
sleep 90

echo "==> Leftover load balancers (should be empty):"
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text || true

terraform destroy "$@"

echo "==> Orphaned EBS volumes (should be empty; delete any you see):"
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table