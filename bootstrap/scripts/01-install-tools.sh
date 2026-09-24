#!/usr/bin/env bash
# Instala k3d e a argocd CLI em ~/bin (idempotente).
set -euo pipefail

BIN_DIR="${HOME}/bin"
mkdir -p "$BIN_DIR"

if [ ! -x "$BIN_DIR/k3d.exe" ]; then
  echo "==> baixando k3d..."
  curl -fsSL -o "$BIN_DIR/k3d.exe" https://github.com/k3d-io/k3d/releases/latest/download/k3d-windows-amd64.exe
else
  echo "==> k3d já instalado: $("$BIN_DIR/k3d.exe" version | head -1)"
fi

if [ ! -x "$BIN_DIR/argocd.exe" ]; then
  echo "==> baixando argocd CLI..."
  curl -fsSL -o "$BIN_DIR/argocd.exe" https://github.com/argoproj/argo-cd/releases/latest/download/argocd-windows-amd64.exe
else
  echo "==> argocd CLI já instalada: $("$BIN_DIR/argocd.exe" version --client --short 2>/dev/null || true)"
fi

echo "==> garanta que $BIN_DIR está no PATH"
