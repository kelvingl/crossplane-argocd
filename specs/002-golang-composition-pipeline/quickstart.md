# Quickstart: Validate the Golang Composition Function Pipeline

Proves User Stories 1, 2, and 3 from `spec.md` end-to-end. Run after
`scripts/00-up.sh` (feature 001's platform) **and** this feature's setup step,
`scripts/11-push-function-and-dataplanes-repos.sh`, have both completed.

## Prerequisites

- `hub`, `spoke-01`, `spoke-02` k3d clusters running.
- ArgoCD synced: `registry`, `crossplane`, `crossplane-providers`,
  `crossplane-config`, `crossplane-compositions` (now Helm-sourced),
  `crossplane-compositions-advanced`. Confirm:
  ```bash
  kubectl --context k3d-hub -n argocd get applications
  ```
- The private registry is reachable and holds the function image:
  ```bash
  curl -sk https://registry.127-0-0-1.nip.io/v2/dataplane-function/tags/list
  ```
- The `dataplanes` repo's `ApplicationSet` has generated its child Applications:
  ```bash
  kubectl --context k3d-hub -n argocd get applicationset dataplanes
  kubectl --context k3d-hub -n argocd get application -l argocd.argoproj.io/instance
  ```

## Story 1 — provision a dataplane by declaring it in Git

The two example dataplanes (`demo-01` → `spoke-01`, `demo-02` → `spoke-02`) are
already pushed by `scripts/11-push-function-and-dataplanes-repos.sh`. Confirm they
converged:

```bash
kubectl --context k3d-hub -n argocd get application dataplane-demo-01 dataplane-demo-02

kubectl --context k3d-hub wait advanceddataplane/demo-01 \
  --for=condition=Ready --timeout=120s

kubectl --context k3d-spoke-01 -n dp-demo-01 get ns,deploy,svc,cm
```

**Expected outcome**: `dp-demo-01` namespace exists on `spoke-01` with a
`ConfigMap`, a `Deployment` (1/1 ready, resource requests/limits set, standardized
labels), and a `Service` — a richer resource set than feature 001's baseline
example. `spoke-02` has nothing related to `demo-01`.

To add a brand-new dataplane yourself (from a local clone of the `dataplanes` repo):

```bash
mkdir demo-03 && cat > demo-03/values.yaml <<'EOF'
spoke: spoke-01
image: nginxdemos/hello
replicas: 1
EOF
git add demo-03 && git commit -m "add demo-03" && git push

# within ~3 min (ApplicationSet poll interval)
kubectl --context k3d-hub -n argocd get application dataplane-demo-03
kubectl --context k3d-spoke-01 -n dp-demo-03 get deploy,svc,cm
```

## Story 2 — update the composition function and roll it out via Helm

```bash
# from a local clone of dataplane-function, after changing main.go
docker build -t registry.127-0-0-1.nip.io/dataplane-function:v0.2.0 .
docker push registry.127-0-0-1.nip.io/dataplane-function:v0.2.0

# bump charts/dataplane-advanced/values.yaml's image tag to v0.2.0, commit+push
# (both to origin/GitHub and to the gogs remote, per Development Workflow)

kubectl --context k3d-hub -n argocd get application crossplane-compositions-advanced
# expect: Synced/Healthy, and the Function resource now references v0.2.0
kubectl --context k3d-hub get function.pkg.crossplane.io dataplane-function \
  -o jsonpath='{.spec.package}{"\n"}'
```

**Expected outcome**: the printed image reference ends in `:v0.2.0`; no manifest was
applied by hand — only a chart `values.yaml` change, released by ArgoCD's Helm sync.

## Story 3 — dataplanes stay independent

```bash
# with demo-01, demo-02, demo-03 all provisioned:
kubectl --context k3d-hub -n argocd delete application dataplane-demo-02 --cascade=foreground
# (equivalent to removing demo-02/ from the dataplanes repo and letting the
#  ApplicationSet prune it)

kubectl --context k3d-spoke-02 get ns dp-demo-02        # expect: NotFound
kubectl --context k3d-spoke-01 -n dp-demo-01 get deploy # still 1/1 ready
kubectl --context k3d-spoke-01 -n dp-demo-03 get deploy # still 1/1 ready
```

**Expected outcome**: only `demo-02`'s resources are gone; `demo-01` and `demo-03`
are completely unaffected, and no shared file (`dataplanes-appset.yaml`, the charts)
needed to change.

## Non-regression check (feature 001 still works)

```bash
kubectl --context k3d-hub -n argocd get application crossplane-compositions
# expect: Synced/Healthy (now Helm-sourced, same rendered output)

kubectl --context k3d-hub get dataplane demo-01 demo-02 -o \
  jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# both still "True" — feature 001's original claims, untouched by this feature
```

## Cleanup

```bash
kubectl --context k3d-hub -n argocd delete application dataplane-demo-01 dataplane-demo-03 --cascade=foreground

kubectl --context k3d-spoke-01 get ns dp-demo-01 dp-demo-03   # expect: NotFound
```
