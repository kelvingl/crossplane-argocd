#!/usr/bin/env bash
# floci-ui's frontend calls http://localhost:4501 directly (hardcoded, no
# configurable API base URL) — it's built assuming the classic docker-compose
# setup where both ports are published on the same host as the browser. The
# Ingress (floci.127-0-0-1.nip.io) works for the static UI shell, but the
# API calls it makes will only resolve if 4501 is *also* reachable at
# localhost on the machine running the browser — which port-forwarding both
# ports here gives you exactly.
set -euo pipefail

echo "==> floci UI:  http://localhost:4500"
echo "==> floci API: http://localhost:4501"
echo "Ctrl+C to stop"
echo ""

kubectl --context k3d-hub -n floci port-forward svc/floci-ui 4500:4500 4501:4501 &
PF_PID=$!

trap "kill $PF_PID 2>/dev/null; exit 0" INT

wait
