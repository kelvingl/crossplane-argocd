#!/usr/bin/env bash
# Floci (like LocalStack) doesn't validate credentials — "test"/"test" is the
# universal convention every public example uses, not a real secret. Still
# generated out-of-band rather than committed, for consistency with how
# every other credential in this lab is handled (constitution Principle V).
set -euo pipefail

kubectl --context k3d-hub -n crossplane-system create secret generic floci-aws-credentials \
  --from-literal=creds="$(cat <<'EOF'
[default]
aws_access_key_id = test
aws_secret_access_key = test
EOF
)" \
  --dry-run=client -o yaml | kubectl --context k3d-hub apply -f -

echo "==> secret floci-aws-credentials criado em crossplane-system"
