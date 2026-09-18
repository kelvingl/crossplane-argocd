#!/usr/bin/env bash
# Gera, para cada spoke, um kubeconfig com o server apontando para o nome
# do container na rede docker compartilhada (em vez do host.docker.internal
# usado pelo kubeconfig padrão do k3d) e cria o Secret correspondente no
# hub, em crossplane-system, para o ProviderConfig do provider-kubernetes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT_DIR/.secrets"
mkdir -p "$SECRETS_DIR"

kubectl --context k3d-hub create namespace crossplane-system \
  --dry-run=client -o yaml | kubectl --context k3d-hub apply -f -

register_spoke() {
  local spoke="$1"
  local server_container="k3d-${spoke}-server-0"
  local kubeconfig="$SECRETS_DIR/${spoke}.kubeconfig"

  echo "==> exportando kubeconfig de '$spoke'"
  k3d kubeconfig get "$spoke" > "$kubeconfig"

  echo "==> reescrevendo server para https://${server_container}:6443"
  sed -i -E "s#server: https://[^:]+:[0-9]+#server: https://${server_container}:6443#" "$kubeconfig"

  echo "==> criando secret ${spoke}-kubeconfig no hub (crossplane-system)"
  kubectl --context k3d-hub -n crossplane-system \
    create secret generic "${spoke}-kubeconfig" \
    --from-file=kubeconfig="$kubeconfig" \
    --dry-run=client -o yaml | kubectl --context k3d-hub apply -f -
}

register_spoke spoke-01
register_spoke spoke-02

echo "==> secrets criados:"
kubectl --context k3d-hub -n crossplane-system get secrets | grep kubeconfig || true
