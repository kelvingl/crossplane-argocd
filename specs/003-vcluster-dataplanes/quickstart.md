# Quickstart: Validate vcluster-Based Dataplane Clusters

Proves User Stories 1, 2, and 3 from `spec.md` end-to-end. Run after the platform is
up (`scripts/00-up.sh`) and `provider-helm`/the redefined `XDataPlane` Composition
have synced.

## Prerequisites

- Only the `hub` k3d cluster exists (`spoke-01`/`spoke-02` no longer created by
  `scripts/02-create-clusters.sh`).
- ArgoCD synced: `crossplane`, `crossplane-providers` (now including
  `provider-helm`), `crossplane-config` (now including the `provider-helm`
  `ProviderConfig`), `crossplane-compositions` (now sourced from
  `compositions/dataplane-cluster/chart`):
  ```bash
  kubectl --context k3d-hub -n argocd get application
  kubectl --context k3d-hub get provider.pkg.crossplane.io provider-helm \
    -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}{"\n"}'
  ```

## Story 1 — provision a new dataplane cluster by submitting a claim

```bash
cat <<'EOF' | kubectl --context k3d-hub apply -f -
apiVersion: lab.example.org/v1alpha1
kind: DataPlane
metadata:
  name: spoke-03
EOF

kubectl --context k3d-hub wait dataplane/spoke-03 --for=condition=Ready --timeout=300s

# the vcluster's own pods, inside the hub:
kubectl --context k3d-hub -n spoke-03 get pods
# its auto-generated kubeconfig Secret (exact name per research.md #4):
kubectl --context k3d-hub -n spoke-03 get secrets | grep -i kubeconfig
```

**Expected outcome**: `spoke-03` reports `Ready`, its namespace has running vcluster
pods in the hub, and a kubeconfig Secret exists — all from one applied claim, zero
k3d/Docker commands.

Register it exactly as any new spoke (existing, unchanged workflow):

```bash
./scripts/16-register-argocd-clusters.sh   # now reads the vcluster's own Secret

kubectl --context k3d-hub get providerconfig.kubernetes.crossplane.io spoke-03
curl -sk https://argocd.127-0-0-1.nip.io/api/v1/clusters | grep -o '"name":"spoke-03"'
```

## Story 2 — everything that already targets a spoke keeps working, unmodified

With `spoke-01`/`spoke-02` migrated (see Migration below), confirm nothing else
changed:

```bash
kubectl --context k3d-hub get advanceddataplane adv-01 -o \
  jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'   # "True"

kubectl --context k3d-hub -n argocd get application dataplane-spoke-01-hello \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'  # Synced Healthy

# the actual workload, now inside the spoke-01 vcluster instead of a real k3d cluster:
kubectl --context k3d-hub -n spoke-01 exec deploy/vcluster-spoke-01 -- \
  kubectl get ns dp-adv-01 deploy,svc -n default
```

**Expected outcome**: no edit was made to `adv-01`'s claim, to
`dataplanes/spoke-01.yaml`, or to the `hello` chart — both keep working exactly as
they did against the real k3d `spoke-01`.

## Story 3 — remove a dataplane cluster by deleting its claim

```bash
kubectl --context k3d-hub delete dataplane spoke-03

kubectl --context k3d-hub get ns spoke-03            # expect: NotFound (eventually)
kubectl --context k3d-hub delete secret cluster-spoke-03 -n argocd
kubectl --context k3d-hub delete providerconfig.kubernetes.crossplane.io spoke-03
```

**Expected outcome**: the vcluster's namespace and everything in it are gone; the
manual cleanup of its `ProviderConfig`/ArgoCD Cluster Secret matches today's
existing behavior for removing any spoke (not new to this feature).

## Migration: spoke-01 / spoke-02 from real k3d clusters to vclusters

```bash
# 1. Claims come from dataplanes/spoke-01.yaml and dataplanes/spoke-02.yaml
#    once the ApplicationSet/wrapper chart change ships — confirm:
kubectl --context k3d-hub get dataplane spoke-01 spoke-02 -o \
  jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}{"\n"}'

# 2. Re-run registration so the ProviderConfig/ArgoCD Cluster point at the
#    new vclusters instead of the (now-removed) real k3d clusters:
./scripts/16-register-argocd-clusters.sh

# 3. selfHeal reconciles everything that targets spoke-01/spoke-02 against the
#    new vclusters automatically — confirm workloads reappear:
kubectl --context k3d-hub -n argocd get application dataplane-spoke-01-adv-01 \
  dataplane-spoke-01-hello dataplane-spoke-02-adv-03 \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# 4. Decommission the old real k3d clusters (no longer needed):
k3d cluster delete spoke-01 spoke-02
```

## Non-regression check: feature 001's original baseline is gone, on purpose

```bash
kubectl --context k3d-hub get xrd xdataplanes.lab.example.org -o \
  jsonpath='{.spec.claimNames.kind}{"\n"}'
# "DataPlane" — same name, confirm it is THIS feature's Composition, not feature 001's:
kubectl --context k3d-hub get composition -o name | grep dataplane-cluster

kubectl --context k3d-spoke-01 get ns dp-demo-01 2>&1 || true
# expect: no such context anymore (spoke-01 is a vcluster context now, not a k3d one) —
# the feature-001 example resources this once held are gone along with the old cluster.
```

## Troubleshooting

Same layered-cache caveat as feature 002 (ArgoCD's `ApplicationSet`/Redis/
repo-server caches can outlive a 3-minute requeue after a
`dataplanes/<spoke>.yaml`, `charts/dataplane-cluster`, or
`compositions/dataplane-cluster` change):

```bash
kubectl --context k3d-hub -n argocd rollout restart deployment/argocd-redis
kubectl --context k3d-hub -n argocd rollout restart deployment/argocd-repo-server deployment/argocd-applicationset-controller
```

If a `DataPlane` claim never reaches `Ready`, check the composed `Release` directly:

```bash
kubectl --context k3d-hub get release.helm.crossplane.io spoke-03 -o yaml
kubectl --context k3d-hub -n crossplane-system logs deploy/provider-helm -f
```

## Cleanup

```bash
kubectl --context k3d-hub delete dataplane spoke-03 2>/dev/null || true
```
