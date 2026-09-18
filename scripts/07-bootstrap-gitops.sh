#!/usr/bin/env bash
# Registra o repo do Gogs como Repository do ArgoCD (declarativo, via
# secret) e aplica a Application raiz (app of apps).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOGS_ADMIN_USER="gitadmin"
GOGS_ADMIN_PASSWORD="ChangeMe123!"
REPO_URL="http://gogs.gogs.svc.cluster.local:3000/gitadmin/platform.git"

echo "==> registrando repository do gogs no argocd"
kubectl --context k3d-hub -n argocd create secret generic gogs-platform-repo \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$GOGS_ADMIN_USER" \
  --from-literal=password="$GOGS_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | \
  kubectl --context k3d-hub -n argocd label --local -f - \
    argocd.argoproj.io/secret-type=repository -o yaml | \
  kubectl --context k3d-hub apply -f -

echo "==> aplicando a Application raiz (app of apps)"
kubectl --context k3d-hub apply -f "$ROOT_DIR/gitops/root/app-of-apps.yaml"

echo "==> aplicações registradas:"
kubectl --context k3d-hub -n argocd get applications
