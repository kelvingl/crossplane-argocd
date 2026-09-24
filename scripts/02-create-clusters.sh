#!/usr/bin/env bash
# Cria o cluster k3d "hub" — o único cluster k3d real deste lab desde a
# feature 003 (vcluster-dataplanes). Dataplanes/spokes não são mais
# clusters k3d separados: são vclusters provisionados dentro do próprio hub
# via claims DataPlane (compositions/dataplane-cluster). A rede docker
# "hublab" continua existindo só para o hub (mantida pelo nome por
# compatibilidade com scripts antigos que possam referenciá-la).
set -euo pipefail

NETWORK="hublab"

echo "==> criando rede docker '$NETWORK' (se não existir)"
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"

create_cluster() {
  local name="$1"; shift
  if k3d cluster list "$name" >/dev/null 2>&1; then
    echo "==> cluster '$name' já existe, pulando"
  else
    echo "==> criando cluster '$name'"
    k3d cluster create "$name" --network "$NETWORK" --wait --timeout 120s "$@"
  fi
}

create_cluster hub -p "80:80@loadbalancer" -p "443:443@loadbalancer"

kubectl config use-context k3d-hub

echo "==> clusters disponíveis:"
k3d cluster list
kubectl config get-contexts
