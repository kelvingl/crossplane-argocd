#!/usr/bin/env bash
# Expose Traefik (Ingress) on host ports 80 and 443
# This allows accessing ArgoCD and Gogs via nip.io domains on the local machine
set -euo pipefail

HUB_LB_CONTAINER=$(docker ps | grep "k3d-hub-serverlb" | awk '{print $1}')

if [ -z "$HUB_LB_CONTAINER" ]; then
  echo "✗ k3d-hub-serverlb container não encontrado"
  exit 1
fi

echo "==> expondo Traefik no host"
echo "Container: $HUB_LB_CONTAINER"
echo ""

# Remove old port mappings if they exist
docker network disconnect bridge "$HUB_LB_CONTAINER" 2>/dev/null || true
sleep 1

# Connect to bridge network with port mappings
docker network connect -p "80:80" -p "443:443" bridge "$HUB_LB_CONTAINER" 2>/dev/null || {
  echo "⚠ Não foi possível expor via bridge (portas podem estar em uso)"
  echo "Alternativa: use 'scripts/09-port-forward.sh' para acesso via localhost:8443"
  exit 1
}

echo "✓ Portas 80 e 443 expostas no host"
echo ""
echo "Acesse:"
echo "  https://argocd.127-0-0-1.nip.io"
echo "  https://git.127-0-0-1.nip.io"
echo ""
echo "Ctrl+C para desconectar"
trap "docker network disconnect bridge $HUB_LB_CONTAINER 2>/dev/null; exit 0" INT

# Keep running
while true; do
  sleep 10
  if ! docker ps | grep -q "$HUB_LB_CONTAINER"; then
    echo "Container desconectou"
    exit 1
  fi
done
