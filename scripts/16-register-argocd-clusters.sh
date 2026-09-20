#!/usr/bin/env bash
# Registra cada spoke como um Cluster do ArgoCD: um Secret com o label
# argocd.argoproj.io/secret-type=cluster no namespace argocd, no formato
# declarativo documentado pelo ArgoCD. Isso faz spoke-01/spoke-02
# aparecerem em Settings > Clusters na UI do ArgoCD e permite endereçar
# uma Application diretamente a um spoke via destination.server/name — até
# agora só o Crossplane "conhecia" os spokes, através dos ProviderConfigs
# do provider-kubernetes.
#
# Reaproveita o mesmo kubeconfig gerado por 03-register-spokes.sh (mesmo
# client-cert/key, mesmo server via IP de container na rede docker
# "hublab", TLS não verificado pelos mesmos motivos documentados lá). O
# Secret não é gerenciado via GitOps (Constitution Principle V — Secrets
# Never Committed) — é criado imperativamente aqui, assim como o Secret de
# kubeconfig consumido pelo provider-kubernetes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT_DIR/.secrets"

register_cluster() {
  local spoke="$1"
  local kubeconfig="$SECRETS_DIR/${spoke}.kubeconfig"

  if [ ! -f "$kubeconfig" ]; then
    echo "!! $kubeconfig não existe — rode scripts/03-register-spokes.sh primeiro" >&2
    exit 1
  fi

  local server cert_data key_data config_json
  server="$(kubectl config view --kubeconfig="$kubeconfig" --raw -o jsonpath='{.clusters[0].cluster.server}')"
  cert_data="$(kubectl config view --kubeconfig="$kubeconfig" --raw -o jsonpath='{.users[0].user.client-certificate-data}')"
  key_data="$(kubectl config view --kubeconfig="$kubeconfig" --raw -o jsonpath='{.users[0].user.client-key-data}')"

  config_json="{\"tlsClientConfig\":{\"insecure\":true,\"certData\":\"${cert_data}\",\"keyData\":\"${key_data}\"}}"

  echo "==> registrando cluster '${spoke}' no ArgoCD (server ${server})"
  kubectl --context k3d-hub -n argocd create secret generic "cluster-${spoke}" \
    --from-literal=name="${spoke}" \
    --from-literal=server="${server}" \
    --from-literal=config="${config_json}" \
    --dry-run=client -o yaml \
  | kubectl --context k3d-hub label --local -f - \
      argocd.argoproj.io/secret-type=cluster -o yaml \
  | kubectl --context k3d-hub apply -f -
}

register_cluster spoke-01
register_cluster spoke-02

echo "==> clusters registrados no ArgoCD:"
kubectl --context k3d-hub -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
