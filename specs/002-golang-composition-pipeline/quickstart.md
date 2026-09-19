# Quickstart: Validate the Golang Composition Function Pipeline

Proves User Stories 1, 2, and 3 from `spec.md` end-to-end. Run after
`scripts/00-up.sh` (feature 001's platform) and this feature's setup:
build+push the function image (`function/Makefile`, or the equivalent
`docker build` + `crossplane xpkg build` + `crossplane xpkg push` steps) and
`scripts/11-push-dataplanes-repo.sh` (creates the `dataplanes` Gogs repo and
registers it with ArgoCD).

**Naming note**: advanced-composition example instances use the `adv-*`
prefix (`adv-01`, `adv-02`, ...), deliberately distinct from feature 001's
baseline examples (`demo-01`, `demo-02`) — both examples target the same
spokes, so they need disjoint claim names to avoid colliding on the same
`dp-<name>` namespace.

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
  kubectl --context k3d-hub -n argocd get application -l argocd.argoproj.io/application-set-name=dataplanes
  ```

## Story 1 — provision a dataplane by declaring it in Git

The two example dataplanes (`adv-01` → `spoke-01`, `adv-02` → `spoke-02`) are
already pushed by `scripts/11-push-dataplanes-repo.sh`. Confirm they converged:

```bash
kubectl --context k3d-hub -n argocd get application dataplane-adv-01 dataplane-adv-02

kubectl --context k3d-hub wait advanceddataplane/adv-01 \
  --for=condition=Ready --timeout=120s

kubectl --context k3d-spoke-01 -n dp-adv-01 get ns,deploy,svc,cm
```

**Expected outcome**: `dp-adv-01` namespace exists on `spoke-01` with a
`ConfigMap`, a `Deployment` (1/1 ready, resource requests/limits set, standardized
labels), and a `Service` — a richer resource set than feature 001's baseline
example. `spoke-02` has nothing related to `adv-01`.

To add a brand-new dataplane yourself (from a local clone of the `dataplanes` repo):

```bash
mkdir adv-03 && cat > adv-03/values.yaml <<'EOF'
spoke: spoke-01
image: nginxdemos/hello
replicas: 1
EOF
git add adv-03 && git commit -m "add adv-03" && git push gogs main

# within ~3 min (ApplicationSet poll interval), or force it sooner with:
# kubectl --context k3d-hub -n argocd patch applicationset dataplanes --type merge -p '{}'
kubectl --context k3d-hub -n argocd get application dataplane-adv-03
kubectl --context k3d-spoke-01 -n dp-adv-03 get deploy,svc,cm
```

## Story 2 — update the composition function and roll it out via Helm

```bash
# from function/, after changing main.go
make -C function TAG=v0.2.0            # docker build + xpkg build + xpkg push
# (no `make` on Windows/Git Bash: run the three commands from function/Makefile by hand)

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
# with adv-01, adv-02, adv-03 all provisioned:
kubectl --context k3d-hub -n argocd delete application dataplane-adv-02 --cascade=foreground
# (equivalent to removing adv-02/ from the dataplanes repo and letting the
#  ApplicationSet prune it)

kubectl --context k3d-spoke-02 get ns dp-adv-02        # expect: NotFound
kubectl --context k3d-spoke-01 -n dp-adv-01 get deploy # still 1/1 ready
kubectl --context k3d-spoke-01 -n dp-adv-03 get deploy # still 1/1 ready
```

**Expected outcome**: only `adv-02`'s resources are gone; `adv-01` and `adv-03`
are completely unaffected, and no shared file (`dataplanes-appset.yaml`, the charts)
needed to change.

## Non-regression check (feature 001 still works)

```bash
kubectl --context k3d-hub -n argocd get application crossplane-compositions
# expect: Synced/Healthy (now Helm-sourced, same rendered output)

kubectl --context k3d-hub apply -f crossplane/examples/claim-dataplane-spoke-01.yaml
kubectl --context k3d-hub apply -f crossplane/examples/claim-dataplane-spoke-02.yaml

kubectl --context k3d-hub get dataplane demo-01 demo-02 -o \
  jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# both "True" — feature 001's original claims/composition, unmodified by this feature

kubectl --context k3d-spoke-01 -n dp-demo-01 get deploy,svc   # baseline, no ConfigMap
kubectl --context k3d-spoke-01 -n dp-adv-01 get deploy,svc,cm # advanced, coexists cleanly
```

## Troubleshooting: ApplicationSet not picking up a change

If a directory add/rename/removal in the `dataplanes` repo doesn't show up as a new
or pruned Application within a few minutes, ArgoCD's layered caches (Redis +
`argocd-repo-server`'s git listing cache) can outlive the `ApplicationSet`
controller's own 3-minute requeue. Force a fresh read with:

```bash
kubectl --context k3d-hub -n argocd rollout restart deployment/argocd-redis
kubectl --context k3d-hub -n argocd rollout restart deployment/argocd-repo-server deployment/argocd-applicationset-controller
```

## Cleanup

```bash
kubectl --context k3d-hub -n argocd delete application dataplane-adv-01 dataplane-adv-03 --cascade=foreground

kubectl --context k3d-spoke-01 get ns dp-adv-01 dp-adv-03   # expect: NotFound
```
