#!/usr/bin/env bash
# Run once per session, right after `terraform apply` + `aws eks update-kubeconfig`.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> SSM secret store + ArgoCD repo credentials"
kubectl apply -f cluster-secret-store.yaml
kubectl apply -f argocd-repo-secret.yaml

echo "==> App namespace + DocumentDB CA bundle"
kubectl create namespace tenderflow --dry-run=client -o yaml | kubectl apply -f -
curl -sSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /tmp/global-bundle.pem
kubectl -n tenderflow create configmap docdb-ca \
  --from-file=global-bundle.pem=/tmp/global-bundle.pem \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Waiting for ArgoCD repo secret to sync from SSM"
kubectl -n argocd wait externalsecret/repo-tenderflow-infra --for=condition=Ready --timeout=60s

echo "==> Root app (ArgoCD takes over from here)"
kubectl apply -f root-app.yaml

echo "Done. Watch: kubectl get applications -n argocd -w"
