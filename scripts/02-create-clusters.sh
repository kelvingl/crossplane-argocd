#!/usr/bin/env bash
# Cria os 3 clusters k3d (hub, spoke-01, spoke-02) na mesma rede docker
# "hublab". O k3d já inclui o nome do container do server (ex.
# k3d-spoke-01-server-0) nos SANs do certificado por padrão, então nenhuma
# flag extra de TLS é necessária aqui. Nesta rede docker (Rancher Desktop),
# porém, a resolução de nome de container não funciona de dentro de outro
# container (não é o DNS embutido clássico do Docker), então
# scripts/03-register-spokes.sh usa o IP do container do spoke, não o nome,
# e desativa a verificação de TLS no kubeconfig gerado para o
# ProviderConfig (lab local — sem isso o hub não alcança o spoke).
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
create_cluster spoke-01
create_cluster spoke-02

kubectl config use-context k3d-hub

echo "==> clusters disponíveis:"
k3d cluster list
kubectl config get-contexts
