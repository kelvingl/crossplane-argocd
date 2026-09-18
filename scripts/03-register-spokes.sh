#!/usr/bin/env bash
# Gera, para cada spoke, um kubeconfig com o server apontando para o IP do
# container do spoke na rede docker compartilhada "hublab" (em vez do
# host.docker.internal usado pelo kubeconfig padrão do k3d) e cria o Secret
# correspondente no hub, em crossplane-system, para o ProviderConfig do
# provider-kubernetes.
#
# Usamos o IP do container, não o nome: nesta rede docker (Rancher Desktop)
# a resolução de nome de container não funciona de dentro de outro
# container. E como o certificado do spoke não tem esse IP nos SANs,
# desativamos a verificação de TLS no kubeconfig gerado — aceitável aqui
# porque é tráfego dentro da rede docker local do lab, nunca exposto.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT_DIR/.secrets"
NETWORK="hublab"
mkdir -p "$SECRETS_DIR"

kubectl --context k3d-hub create namespace crossplane-system \
  --dry-run=client -o yaml | kubectl --context k3d-hub apply -f -

register_spoke() {
  local spoke="$1"
  local server_container="k3d-${spoke}-server-0"
  local kubeconfig="$SECRETS_DIR/${spoke}.kubeconfig"

  local ip
  ip="$(docker inspect "$server_container" \
    --format "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}")"
  if [ -z "$ip" ]; then
    echo "!! não achei o IP de ${server_container} na rede ${NETWORK}" >&2
    exit 1
  fi

  echo "==> exportando kubeconfig de '$spoke'"
  k3d kubeconfig get "$spoke" > "$kubeconfig"

  echo "==> reescrevendo server para https://${ip}:6443 (TLS verify off)"
  sed -i -E "s#server: https://[^:]+:[0-9]+#server: https://${ip}:6443#" "$kubeconfig"
  sed -i -E "/certificate-authority-data:/d" "$kubeconfig"
  sed -i -E "s#(server: https://.*)#insecure-skip-tls-verify: true\n    \1#" "$kubeconfig"

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
