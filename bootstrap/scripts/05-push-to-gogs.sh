#!/usr/bin/env bash
# Cria o usuário admin e o repositório "platform" no Gogs, e faz o push
# deste repositório local para lá. Usa port-forward apenas durante este
# script; depois disso o ArgoCD fala com o Gogs via DNS interno do cluster.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOGS_ADMIN_USER="gitadmin"
GOGS_ADMIN_PASSWORD="ChangeMe123!"
GOGS_ADMIN_EMAIL="admin@lab.local"
REPO_NAME="platform"
LOCAL_PORT="30300"  # porta 3000 local costuma já estar em uso por outra coisa

cleanup() {
  if [ -n "${PF_PID:-}" ]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> criando usuário admin no gogs (ignora erro se já existir)"
# MSYS_NO_PATHCONV evita que o Git Bash reescreva "/app/gogs/gogs" (caminho
# dentro do container) como um caminho de arquivo do Windows. "kubectl exec"
# entra no container como root, mas o Gogs está configurado para rodar como
# o usuário "git" (RUN_USER) e recusa comandos executados como outro
# usuário — por isso usamos "gosu git" para trocar de usuário antes.
MSYS_NO_PATHCONV=1 kubectl --context k3d-hub -n gogs exec deploy/gogs -- \
  gosu git /app/gogs/gogs admin create-user \
    --name "$GOGS_ADMIN_USER" \
    --password "$GOGS_ADMIN_PASSWORD" \
    --email "$GOGS_ADMIN_EMAIL" \
    --admin || echo "(usuário provavelmente já existe, seguindo)"

echo "==> port-forward para gogs em localhost:$LOCAL_PORT"
kubectl --context k3d-hub -n gogs port-forward svc/gogs "${LOCAL_PORT}:3000" >/tmp/gogs-pf.log 2>&1 &
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

cd "$ROOT_DIR"
if [ ! -d .git ]; then
  git init -b main
fi
git add -A
if ! git diff --cached --quiet; then
  git -c user.email="${GOGS_ADMIN_EMAIL}" -c user.name="lab-bootstrap" \
    commit -m "Sync platform GitOps config"
else
  echo "==> nada para commitar, seguindo com o push do que já existe"
fi

git remote remove gogs 2>/dev/null || true
git remote add gogs "http://${GOGS_ADMIN_USER}:${GOGS_ADMIN_PASSWORD}@localhost:${LOCAL_PORT}/${GOGS_ADMIN_USER}/${REPO_NAME}.git"
git push gogs main -f

echo "==> push concluído. Repo interno: http://gogs.gogs.svc.cluster.local:3000/${GOGS_ADMIN_USER}/${REPO_NAME}.git"
