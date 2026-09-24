#!/usr/bin/env bash
set -euo pipefail

kubectl --context k3d-hub create namespace argocd \
  --dry-run=client -o yaml | kubectl --context k3d-hub apply -f -

echo "==> instalando argocd (stable)"
# --server-side: o CRD do ApplicationSet é grande demais para caber na
# anotação last-applied-configuration que o "apply" client-side normal usa.
kubectl --context k3d-hub apply --server-side --force-conflicts \
  -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> aguardando argocd-server"
kubectl --context k3d-hub -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl --context k3d-hub -n argocd rollout status deployment/argocd-repo-server --timeout=300s

# Lab local, sem exposição externa real: desliga o login do ArgoCD em vez de
# usar uma senha fixa (ex: admin/admin). Acesso anônimo vira admin.
echo "==> habilitando acesso anônimo (role:admin) — sem login, lab-only"
kubectl --context k3d-hub -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"users.anonymous.enabled":"true"}}'
kubectl --context k3d-hub -n argocd patch cm argocd-rbac-cm --type merge \
  -p '{"data":{"policy.default":"role:admin"}}'
kubectl --context k3d-hub -n argocd rollout restart deployment/argocd-server
kubectl --context k3d-hub -n argocd rollout status deployment/argocd-server --timeout=120s

echo "==> login desligado: qualquer acesso ao ArgoCD já entra como admin"
