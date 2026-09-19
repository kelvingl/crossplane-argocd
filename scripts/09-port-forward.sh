#!/usr/bin/env bash
# Expose ArgoCD and Gogs via local port-forward
set -euo pipefail

echo "==> exposing services via port-forward"
echo "ArgoCD:  http://localhost:8080  (porta local)"
echo "Gogs:    http://localhost:3000  (porta local)"
echo ""
echo "Para usar os domínios nip.io, adicione ao /etc/hosts:"
echo "127.0.0.1 argocd.127-0-0-1.nip.io"
echo "127.0.0.1 git.127-0-0-1.nip.io"
echo ""
echo "Ctrl+C para parar"
echo ""

kubectl --context k3d-hub port-forward -n argocd svc/argocd-server 8080:443 &
ARGOCD_PID=$!

kubectl --context k3d-hub port-forward -n gogs svc/gogs 3000:3000 &
GOGS_PID=$!

trap "kill $ARGOCD_PID $GOGS_PID 2>/dev/null; exit 0" INT

wait
