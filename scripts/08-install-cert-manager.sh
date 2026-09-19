#!/usr/bin/env bash
# Instala cert-manager e cria ClusterIssuers para Let's Encrypt.
set -euo pipefail

echo "==> instalando cert-manager"
kubectl --context k3d-hub apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

echo "==> aguardando rollout do cert-manager"
kubectl --context k3d-hub rollout status deployment/cert-manager -n cert-manager --timeout=120s

echo "==> cert-manager instalado"
