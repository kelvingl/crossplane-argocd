#!/usr/bin/env bash
# Expose ArgoCD and Gogs via local port-forward (with HTTPS via Traefik)
set -euo pipefail

echo "==> exposing services via port-forward"
echo ""
echo "HTTPS (via Traefik + cert-manager):"
echo "  ArgoCD:  https://localhost:8443  -H 'Host: argocd.127-0-0-1.nip.io'"
echo "  Gogs:    https://localhost:8443  -H 'Host: git.127-0-0-1.nip.io'"
echo ""
echo "Para usar os domínios nip.io diretamente, adicione ao /etc/hosts:"
echo "  127.0.0.1 argocd.127-0-0-1.nip.io"
echo "  127.0.0.1 git.127-0-0-1.nip.io"
echo ""
echo "Depois acesse (ignore avisos de certificado auto-assinado):"
echo "  https://argocd.127-0-0-1.nip.io"
echo "  https://git.127-0-0-1.nip.io"
echo ""
echo "Ctrl+C para parar"
echo ""

# Traefik HTTPS
kubectl --context k3d-hub port-forward -n kube-system svc/traefik 8443:443 &
TRAEFIK_HTTPS_PID=$!

# Traefik HTTP (redirect to HTTPS)
kubectl --context k3d-hub port-forward -n kube-system svc/traefik 8080:80 &
TRAEFIK_HTTP_PID=$!

trap "kill $TRAEFIK_HTTPS_PID $TRAEFIK_HTTP_PID 2>/dev/null; exit 0" INT

wait
