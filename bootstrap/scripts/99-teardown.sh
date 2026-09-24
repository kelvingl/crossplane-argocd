#!/usr/bin/env bash
set -euo pipefail

for c in hub spoke-01 spoke-02; do
  k3d cluster delete "$c" || true
done

docker network rm hublab >/dev/null 2>&1 || true

rm -rf "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.secrets"

echo "==> lab removido"
