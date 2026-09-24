#!/usr/bin/env bash
# Roda todo o setup do lab, em ordem.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./01-install-tools.sh
./02-create-clusters.sh
./04-bootstrap-gogs.sh
./05-push-to-gogs.sh
./06-install-argocd.sh
./07-bootstrap-gitops.sh

echo
echo "==> lab no ar. Veja o README.md para testar a composition e acessar as UIs."
