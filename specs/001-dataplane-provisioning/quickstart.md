# Quickstart: Validate Hub-and-Spoke Dataplane Provisioning

Proves User Stories 1 and 2 from `spec.md` end-to-end. Run after the platform is up
(`scripts/00-up.sh`, or steps 02–07 individually — see repo `README.md`).

## Prerequisites

- `hub`, `spoke-01`, `spoke-02` k3d clusters running (`k3d cluster list`)
- ArgoCD has synced `crossplane`, `crossplane-providers`, and `crossplane-config` —
  confirm with:
  ```bash
  kubectl --context k3d-hub -n argocd get applications
  ```
  `crossplane-config` (which installs the `ProviderConfig`s = Spoke Registrations)
  should be `Synced`/`Healthy` before continuing.

## Story 1 — provision into a chosen spoke

```bash
kubectl --context k3d-hub apply -f crossplane/examples/claim-dataplane-spoke-01.yaml

# wait for Ready
kubectl --context k3d-hub wait dataplane/demo-01 -n default \
  --for=condition=Ready --timeout=120s

# verify directly on the spoke (per SC-003: must exist, verifiable by inspection)
kubectl --context k3d-spoke-01 -n dp-demo-01 get deploy,svc
```

**Expected outcome**: `dp-demo-01` namespace exists on `spoke-01` with a
`dataplane-demo-01` Deployment (1/1 ready) and Service. `spoke-02` has nothing
related to `demo-01` (namespace `dp-demo-01` does not exist there).

## Story 2 — customize image and replica count

```bash
kubectl --context k3d-hub apply -f crossplane/examples/claim-dataplane-spoke-02.yaml

kubectl --context k3d-hub wait dataplane/demo-02 -n default \
  --for=condition=Ready --timeout=120s

kubectl --context k3d-spoke-02 -n dp-demo-02 get deploy dataplane-demo-02 \
  -o jsonpath='{.spec.replicas}{"\n"}{.spec.template.spec.containers[0].image}{"\n"}'
```

**Expected outcome**: prints `2` then `nginxdemos/hello` — matching
`crossplane/examples/claim-dataplane-spoke-02.yaml`'s `spec.parameters`, distinct
from `demo-01`'s defaults.

## Isolation check (SC-005)

```bash
kubectl --context k3d-hub get dataplane -A
kubectl --context k3d-spoke-01 get ns | grep dp-
kubectl --context k3d-spoke-02 get ns | grep dp-
```

**Expected outcome**: `demo-01`'s namespace (`dp-demo-01`) exists only on
`spoke-01`; `demo-02`'s (`dp-demo-02`) exists only on `spoke-02`. Neither spoke has
the other's namespace.

## Cleanup

```bash
kubectl --context k3d-hub delete -f crossplane/examples/claim-dataplane-spoke-01.yaml
kubectl --context k3d-hub delete -f crossplane/examples/claim-dataplane-spoke-02.yaml

# confirm cascading delete reached the spokes
kubectl --context k3d-spoke-01 get ns dp-demo-01   # expect: NotFound
kubectl --context k3d-spoke-02 get ns dp-demo-02   # expect: NotFound
```
