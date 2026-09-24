#!/usr/bin/env bash
# Cria o repositório "dataplanes" no Gogs (uma pasta por dataplane, com seu
# values.yaml) e faz push do working copy local para lá. Também registra o
# repo como Repository secret no ArgoCD, para o ApplicationSet
# (gitops/apps/dataplanes-appset.yaml) conseguir lê-lo.
#
# Diferente da function (que agora vive dentro deste mesmo repo, em
# function/), o repo de declarações de dataplanes é propositalmente um repo
# Gogs separado — é a fonte de verdade de "quais dataplanes existem",
# editado independentemente do código da plataforma.
set -euo pipefail

DATAPLANES_DIR="${DATAPLANES_DIR:-../dataplanes}"
GOGS_ADMIN_USER="gitadmin"
GOGS_ADMIN_PASSWORD="ChangeMe123!"
GOGS_ADMIN_EMAIL="admin@lab.local"
REPO_NAME="dataplanes"
LOCAL_PORT="30300"

cleanup() {
  if [ -n "${PF_PID:-}" ]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ ! -d "$DATAPLANES_DIR" ]; then
  echo "✗ $DATAPLANES_DIR não existe (veja specs/002-golang-composition-pipeline/quickstart.md)"
  exit 1
fi

echo "==> port-forward para gogs em localhost:$LOCAL_PORT"
kubectl --context k3d-hub -n gogs port-forward svc/gogs "${LOCAL_PORT}:3000" >/tmp/gogs-pf-dataplanes.log 2>&1 &
PF_PID=$!

for i in $(seq 1 30); do
  if curl -fsS "http://localhost:${LOCAL_PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> criando repositório '$REPO_NAME' via API do gogs"
curl -fsS -u "${GOGS_ADMIN_USER}:${GOGS_ADMIN_PASSWORD}" \
  -X POST "http://localhost:${LOCAL_PORT}/api/v1/admin/users/${GOGS_ADMIN_USER}/repos" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"private\":false,\"auto_init\":false}" \
  || echo "(repo provavelmente já existe, seguindo)"

pushd "$DATAPLANES_DIR" >/dev/null
if [ ! -d .git ]; then
  git init -b main
fi
git add -A
if ! git diff --cached --quiet; then
  git -c user.email="${GOGS_ADMIN_EMAIL}" -c user.name="lab-bootstrap" \
    commit -m "Sync dataplanes declarations"
else
  echo "==> nada para commitar, seguindo com o push do que já existe"
fi

git remote remove gogs 2>/dev/null || true
git remote add gogs "http://${GOGS_ADMIN_USER}:${GOGS_ADMIN_PASSWORD}@localhost:${LOCAL_PORT}/${GOGS_ADMIN_USER}/${REPO_NAME}.git"
git push gogs main -f
popd >/dev/null

echo "==> registrando repositório '$REPO_NAME' no ArgoCD"
kubectl --context k3d-hub -n argocd create secret generic "${REPO_NAME}-repo" \
  --from-literal=type=git \
  --from-literal=url="http://gogs.gogs.svc.cluster.local:3000/${GOGS_ADMIN_USER}/${REPO_NAME}.git" \
  --from-literal=username="${GOGS_ADMIN_USER}" \
  --from-literal=password="${GOGS_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl --context k3d-hub -n argocd label --local -f - \
  argocd.argoproj.io/secret-type=repository -o yaml | kubectl --context k3d-hub apply -f -

echo "==> push concluído. Repo interno: http://gogs.gogs.svc.cluster.local:3000/${GOGS_ADMIN_USER}/${REPO_NAME}.git"
