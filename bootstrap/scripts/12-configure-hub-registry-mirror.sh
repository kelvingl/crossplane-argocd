#!/usr/bin/env bash
# k3s's containerd resolves image references using the hub NODE's network
# namespace, not a pod's — so it can't resolve *.svc.cluster.local (that only
# works inside pod network namespaces via CoreDNS). This registers a
# containerd registry mirror on the hub node that redirects the friendly
# in-cluster hostname to the registry Service's fixed ClusterIP instead, and
# trusts the lab's self-signed CA for it. Re-run after recreating the hub
# cluster or rotating the CA.
set -euo pipefail

NODE="k3d-hub-server-0"
REGISTRY_IP="10.43.0.50"
REGISTRY_HOST="registry.registry.svc.cluster.local:5000"

echo "==> extraindo CA do cluster"
kubectl --context k3d-hub -n cert-manager get secret lab-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/lab-ca.crt

echo "==> escrevendo registries.yaml e CA no node $NODE"
docker cp /tmp/lab-ca.crt "$NODE:/etc/rancher/k3s/lab-ca.crt"

REGISTRIES_FILE="$(dirname "$0")/../.registries.yaml.tmp"
cat > "$REGISTRIES_FILE" <<EOF
mirrors:
  "${REGISTRY_HOST}":
    endpoint:
      - "https://${REGISTRY_IP}:5000"
configs:
  "${REGISTRY_HOST}":
    tls:
      ca_file: /etc/rancher/k3s/lab-ca.crt
  "${REGISTRY_IP}:5000":
    # containerd's mirror client verifies TLS against the endpoint it
    # actually connects to (the IP above), not the original hostname, so the
    # CA must be registered under both keys.
    tls:
      ca_file: /etc/rancher/k3s/lab-ca.crt
EOF
docker cp "$REGISTRIES_FILE" "$NODE:/etc/rancher/k3s/registries.yaml"
rm -f "$REGISTRIES_FILE"

echo "==> reiniciando o node para o containerd recarregar a config"
docker restart "$NODE"

echo "==> aguardando o hub voltar"
until kubectl --context k3d-hub get nodes >/dev/null 2>&1; do sleep 2; done
kubectl --context k3d-hub wait --for=condition=Ready node --all --timeout=120s

echo "==> registries.yaml aplicado. ${REGISTRY_HOST} agora resolve para ${REGISTRY_IP}:5000 no node."
