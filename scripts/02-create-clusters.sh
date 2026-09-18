#!/usr/bin/env bash
# Cria os 3 clusters k3d (hub, spoke-01, spoke-02) na mesma rede docker
# "hublab", para que o hub consiga alcançar a API dos spokes pelo nome do
# container. Cada spoke recebe --tls-san com o nome do seu container de
# server, senão a validação TLS falha quando o hub conecta por esse nome.
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

create_cluster hub
create_cluster spoke-01 --tls-san k3d-spoke-01-server-0
create_cluster spoke-02 --tls-san k3d-spoke-02-server-0

kubectl config use-context k3d-hub

echo "==> clusters disponíveis:"
k3d cluster list
kubectl config get-contexts
