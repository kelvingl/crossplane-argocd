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
# Então a criação do Secret de credenciais continua imperativa aqui; só a
# *lista* de quais spokes registrar vem do Git.
#
# Feature 003 (vcluster): cada spoke agora é um vcluster dentro do hub, não
# mais um cluster k3d separado. O kubeconfig vem do Secret que o próprio
# chart do vcluster gera em tempo de execução (namespace = nome do spoke,
# Secret "vc-<spoke>"), com chaves já separadas
# (certificate-authority/client-certificate/client-key) — não precisa mais
# fazer parsing de kubeconfig via `kubectl config view` como no modelo k3d
# antigo (scripts/03-register-spokes.sh, agora removido). O server é
# previsível: "https://<spoke>.<spoke>:443" (a forma curta "nome.namespace"
# — o certificado do vcluster só cobre essa forma, não o FQDN completo
# "...svc.cluster.local"; ver specs/003-vcluster-dataplanes/research.md #2).
#
# O label extra "lab.example.org/role=dataplane" (além do
# "argocd.argoproj.io/secret-type=cluster" que o ArgoCD exige) é o que o
# ApplicationSet "dataplane-addons" (gerador `clusters`) usa para selecionar
# só os spokes — sem ele, o gerador `clusters` também incluiria o
# `in-cluster` implícito (o próprio hub).
set -euo pipefail

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
  local secret_name="vc-${spoke}"

  if ! kubectl --context k3d-hub -n "$spoke" get secret "$secret_name" >/dev/null 2>&1; then
    echo "!! secret ${spoke}/${secret_name} não existe — o vcluster ainda não subiu? (aguarde o DataPlane claim '${spoke}' ficar Ready)" >&2
    exit 1
  fi

  local server ca_data cert_data key_data config_json
  server="https://${spoke}.${spoke}:443"
  ca_data="$(kubectl --context k3d-hub -n "$spoke" get secret "$secret_name" -o jsonpath='{.data.certificate-authority}')"
  cert_data="$(kubectl --context k3d-hub -n "$spoke" get secret "$secret_name" -o jsonpath='{.data.client-certificate}')"
  key_data="$(kubectl --context k3d-hub -n "$spoke" get secret "$secret_name" -o jsonpath='{.data.client-key}')"

  config_json="{\"tlsClientConfig\":{\"caData\":\"${ca_data}\",\"certData\":\"${cert_data}\",\"keyData\":\"${key_data}\"}}"

  echo "==> registrando cluster '${spoke}' no ArgoCD (server ${server})"
  kubectl --context k3d-hub -n argocd create secret generic "cluster-${spoke}" \
    --from-literal=name="${spoke}" \
    --from-literal=server="${server}" \
    --from-literal=config="${config_json}" \
    --dry-run=client -o yaml \
  | kubectl --context k3d-hub label --local -f - \
      argocd.argoproj.io/secret-type=cluster \
      lab.example.org/role=dataplane \
      -o yaml \
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
