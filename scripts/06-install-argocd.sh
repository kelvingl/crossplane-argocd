#!/usr/bin/env bash
set -euo pipefail

kubectl --context k3d-hub create namespace argocd \
  --dry-run=client -o yaml | kubectl --context k3d-hub apply -f -

echo "==> instalando argocd (stable)"
kubectl --context k3d-hub apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> aguardando argocd-server"
kubectl --context k3d-hub -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl --context k3d-hub -n argocd rollout status deployment/argocd-repo-server --timeout=300s

echo "==> senha inicial do admin:"
kubectl --context k3d-hub -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
