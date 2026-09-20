#!/usr/bin/env bash
# Registra, como Cluster do ArgoCD, cada spoke declarado no repositório
# "dataplanes" em dataplanes/<spoke>.yaml (campo "cluster:") — o mesmo
# arquivo que também lista quais charts/compositions rodam nesse spoke (ver
# README desse repo). Como spoke = cluster = dataplane, um arquivo só faz
# as duas coisas: "isto existe" (registrado aqui) e "isto roda nele" (lido
# pelo ApplicationSet "dataplanes" via git files generator). O repositório
# dataplanes é a fonte de verdade de "quais clusters devem existir"; este
# script só aplica.
#
# Por que um script, e não um ApplicationSet/Helm chart: tentamos primeiro
# um chart com Helm `lookup` lendo o kubeconfig do spoke ao vivo (evitando
# credenciais em qualquer lugar do fluxo declarativo), mas o repo-server do
# ArgoCD roda `helm template` sem acesso ao cluster — `lookup` sempre
# retorna vazio ali, mesmo com o Secret existindo (testado, não suposto).
# Então a criação do Secret de credenciais continua imperativa aqui, como o
# Secret de kubeconfig do provider-kubernetes (Constitution Principle V —
# Secrets Never Committed); só a *lista* de quais spokes registrar passou a
# vir do Git.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT_DIR/.secrets"
GOGS_ADMIN_USER="gitadmin"
GOGS_ADMIN_PASSWORD="ChangeMe123!"
LOCAL_PORT="48765"
TMP_CLONE="$(mktemp -d)"

cleanup() {
  if [ -n "${PF_PID:-}" ]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_CLONE"
}
trap cleanup EXIT

echo "==> port-forward para gogs em localhost:$LOCAL_PORT"
kubectl --context k3d-hub -n gogs port-forward svc/gogs "${LOCAL_PORT}:3000" >/tmp/gogs-pf-clusters.log 2>&1 &
PF_PID=$!

for i in $(seq 1 30); do
  if curl -fsS "http://localhost:${LOCAL_PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> clonando repositório 'dataplanes' do gogs"
# --branch main explícito: o repo foi criado via API do Gogs sem auto_init,
# então o HEAD/default_branch reportado ("master") não existe de verdade —
# só o branch "main", que é o que 11-push-dataplanes-repo.sh de fato usa.
git clone --depth 1 --quiet --branch main \
  "http://${GOGS_ADMIN_USER}:${GOGS_ADMIN_PASSWORD}@localhost:${LOCAL_PORT}/${GOGS_ADMIN_USER}/dataplanes.git" \
  "$TMP_CLONE"

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

if [ ! -d "$TMP_CLONE/dataplanes" ]; then
  echo "!! $TMP_CLONE/dataplanes não existe no repo dataplanes — nada para registrar" >&2
  exit 0
fi

for f in "$TMP_CLONE"/dataplanes/*.yaml; do
  [ -e "$f" ] || continue
  spoke="$(sed -n -E 's/^cluster: *"?([^"[:space:]]+)"?.*/\1/p' "$f" | head -n1)"
  if [ -z "$spoke" ]; then
    echo "!! $f não tem campo 'cluster:' — pulando" >&2
    continue
  fi
  register_cluster "$spoke"
done

echo "==> clusters registrados no ArgoCD:"
kubectl --context k3d-hub -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
