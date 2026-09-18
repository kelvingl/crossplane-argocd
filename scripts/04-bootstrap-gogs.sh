#!/usr/bin/env bash
# Sobe o Gogs no hub de forma imperativa (bootstrap). Depois que o ArgoCD
# existir, a Application "gogs" (gitops/apps/gogs.yaml) aponta para os
# mesmos manifests e passa a gerenciá-los via GitOps.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl --context k3d-hub apply -f "$ROOT_DIR/bootstrap/gogs/"

echo "==> aguardando rollout do gogs"
kubectl --context k3d-hub -n gogs rollout status deployment/gogs --timeout=180s

echo "==> gogs no ar"
