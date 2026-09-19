# Implementation Plan: Golang Composition Function Pipeline (Registry + Helm + Dataplanes Repo)

**Branch**: `002-golang-composition-pipeline` | **Date**: 2026-09-19 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/002-golang-composition-pipeline/spec.md`

## Summary

Add a second, more advanced way to provision a dataplane, alongside the existing
Patch-and-Transform example from feature 001 (which keeps working unmodified). A new
Crossplane Composition Function, written in Go and built into a container image, is
published to a private OCI registry running in the hub. A new `AdvancedDataPlane`
claim (backed by `spec.mode: Pipeline` calling that function) composes a richer
resource set (Namespace, ConfigMap, Deployment with resource limits/labels, Service)
into the chosen spoke, exactly as today's provider-kubernetes model already does.
Both this Composition and the pre-existing one are installed/upgraded via Helm charts
(no more directory-of-manifests Applications for Compositions). The Go function's
source lives in its own Gogs repository (`dataplane-function`), separate from the
platform repo. A new Gogs repository (`dataplanes`) holds one directory per dataplane
instance (a `values.yaml` each); an ArgoCD `ApplicationSet` discovers those
directories and turns each into its own Helm release, so adding/removing a dataplane
is a pure Git operation with zero shared-file changes.

## Technical Context

**Language/Version**: Go 1.22+ (Composition Function server, via
`crossplane-runtime`'s `function-sdk-go`); declarative Kubernetes/Helm YAML for
everything else; POSIX shell for bootstrap automation (`scripts/`).

**Primary Dependencies**: `crossplane-runtime` `function-sdk-go` (gRPC composition
function protocol), Crossplane v1.20.13 (function-pipeline mode, `spec.mode:
Pipeline`, alongside the existing classic mode from feature 001),
`provider-kubernetes` v1.3.1 (unchanged — still the only way a composed resource
reaches a spoke), CNCF `distribution/distribution` v2 (private OCI registry), Helm 3
(chart packaging for every Composition), ArgoCD `ApplicationSet` (git generator,
directories) for the dataplanes-repo → Helm-release fan-out, Gogs 0.14 (two new
repositories: `dataplane-function`, `dataplanes`).

**Storage**: Kubernetes `Secret`s (spoke kubeconfigs — unchanged; any registry
push/pull credential, if later added) plus a `PersistentVolumeClaim` for the private
registry's blob storage. No dedicated database; Gogs continues to own its own SQLite
DB + git repos on its existing PVC (now holding two more repos).

**Testing**: No automated test suite — this remains an infra lab. Validation is
manual/scripted: build+push the function image, install both Helm charts via
ArgoCD, add dataplane directories to the `dataplanes` repo, and confirm resources in
the target spokes via `kubectl --context k3d-spoke-0N`, exactly as `quickstart.md`
in feature 001 did. See this feature's `quickstart.md`.

**Target Platform**: The same three k3d clusters (`hub`, `spoke-01`, `spoke-02`) on
the shared `hublab` Docker network; the private registry and the two new Gogs repos
run inside/alongside the existing `hub` cluster's Gogs instance — no new cluster.

**Project Type**: Infrastructure / GitOps platform configuration, plus one small Go
service (the Composition Function) that only the hub's Crossplane pipeline calls —
not a project with its own user-facing runtime.

**Performance Goals**: Same order of magnitude as feature 001's SC-001/SC-002 (spec
SC-002: dataplane observable in its spoke within 2 minutes of the values file being
pushed, assuming images are already cached).

**Constraints**: A Composition Function MUST reach the target spoke only through
`provider-kubernetes` + `providerConfigRef.name` (constitution Principle II,
unchanged). A Composition Function's image MUST be servable from the private,
GitOps-provisioned registry with no runtime dependency on a public registry
(constitution Technology Constraints, amended v1.1.0). Any Composition ArgoCD
installs/upgrades MUST be a Helm chart release (same amendment). Everything except
the out-of-band spoke kubeconfig Secrets and any registry credential MUST be
Git-tracked and ArgoCD-reconciled (Principle I).

**Scale/Scope**: Two example dataplane instances in the new `dataplanes` repo (one
per spoke), mirroring feature 001's two example claims; adding an Nth MUST require
touching only that Nth directory (spec SC-005).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against constitution **v1.1.0** (amended 2026-09-19 specifically to permit
the pattern this feature needs).

| Principle | Status | Notes |
|---|---|---|
| I. GitOps-Only Changes | PASS | Registry, both Helm charts, and the ApplicationSet are all Git-tracked under this repo and reconciled by ArgoCD. The two new Gogs repos (`dataplane-function`, `dataplanes`) are themselves git sources ArgoCD/ApplicationSet reads from — consistent with how the platform repo already works. Only new one-time step: creating those two repos and pushing their initial content, done via a numbered script (`scripts/11-*`), matching how `scripts/05-push-to-gogs.sh` bootstrapped the platform repo. |
| II. Hub-and-Spoke Isolation | PASS | The new Composition Function still delegates all spoke-reaching work to `provider-kubernetes` `Object`s with `providerConfigRef.name` sourced from `spec.parameters.spoke` — the function computes *what* to compose, it never talks to a spoke API server itself. No platform tooling is added to any spoke. |
| III. App-of-Apps Structure | PASS | Three new child Applications under `gitops/apps/` (`registry.yaml` sync-wave 0, `crossplane-compositions-advanced.yaml` sync-wave 1) plus one `ApplicationSet` manifest (`dataplanes-appset.yaml`, wave 2) — all discovered the same way existing children are, none applied by hand. `crossplane-compositions.yaml` (existing, feature 001) is edited in place to switch its source from `directory` to `helm`, keeping its sync-wave. |
| IV. Composable, Testable Compositions | PASS (planned) | The new `XDataPlaneAdvanced`/`AdvancedDataPlane` ships with the `dataplane-advanced` chart and at least one real instance declared in the `dataplanes` repo per spoke, verified end-to-end before this feature is done — the dataplanes-repo instances satisfy Principle IV's "example claim" requirement for this Composition, per the wording added in constitution v1.1.0. The pre-existing `XDataPlane`/`DataPlane` example from feature 001 is preserved unmodified (FR-010) — only re-packaged as a Helm chart, not behaviorally changed. |
| V. Secrets Never Committed | PASS | No new credential is strictly required for v1 (registry has no auth for pull; push happens from the operator's already-trusted local Docker). If a push credential is later added, it follows the existing `.secrets/`/`Secret` pattern — called out explicitly in Assumptions so it isn't silently skipped. |

No unjustified violations — no Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/002-golang-composition-pipeline/
├── plan.md                          # This file
├── research.md                      # Phase 0 output
├── data-model.md                    # Phase 1 output
├── quickstart.md                    # Phase 1 output
├── contracts/
│   └── dataplane-instance-values.md # Contract for a dataplanes-repo directory
└── tasks.md                         # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

This feature spans the platform repo (this checkout) plus two brand-new,
standalone Gogs-only repositories authored locally and pushed from here.

```text
# argo-crossplane (this repo — pushed to GitHub + Gogs, as today)
registry/
├── namespace.yaml
├── pvc.yaml
├── deployment.yaml                  # distribution/distribution:2, hub-local
├── service.yaml                     # registry.registry.svc.cluster.local:5000
└── ingress.yaml                     # registry.127-0-0-1.nip.io (Traefik + lab-ca-issuer)

charts/
├── dataplane-baseline/              # Feature 001's XRD/Composition, now Helm-packaged
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── xrd-dataplane.yaml
│       └── composition-dataplane-k8s.yaml
├── dataplane-advanced/              # This feature's Function-pipeline Composition
│   ├── Chart.yaml
│   ├── values.yaml                  # default function image ref (private registry)
│   └── templates/
│       ├── xrd-dataplane-advanced.yaml
│       ├── function.yaml            # Crossplane `Function`, image from private registry
│       └── composition-dataplane-advanced.yaml   # spec.mode: Pipeline
└── dataplane-instance/              # Tiny chart: renders one AdvancedDataPlane claim
    ├── Chart.yaml
    ├── values.yaml                  # schema mirrors contracts/dataplane-instance-values.md
    └── templates/
        └── claim.yaml

gitops/apps/
├── registry.yaml                    # NEW — sync-wave 0, directory source → registry/
├── crossplane-compositions.yaml     # EDITED — directory → helm (compositions/dataplane-baseline/chart)
├── crossplane-compositions-advanced.yaml  # NEW — sync-wave 1, helm (compositions/dataplane-advanced/chart)
└── dataplanes-appset.yaml           # NEW — ApplicationSet, git-directories generator over
                                      #       the `dataplanes` Gogs repo, multi-source Helm
                                      #       release per directory (chart from this repo,
                                      #       values from the matching directory)

scripts/
└── 11-push-function-and-dataplanes-repos.sh   # NEW — creates+pushes the two Gogs repos,
                                                #       builds+pushes the function image

# dataplane-function (NEW, standalone repo — Gogs only, authored under
# a local working copy outside this checkout, e.g. ../dataplane-function/)
go.mod
main.go            # function-sdk-go RunFunction: composes Namespace/ConfigMap/
                    # Deployment/Service as provider-kubernetes Objects
Dockerfile          # multi-stage Go build → distroless runtime image

# dataplanes (NEW, standalone repo — Gogs only, authored under
# a local working copy outside this checkout, e.g. ../dataplanes/)
demo-01/
└── values.yaml     # spoke: spoke-01, image, replicas
demo-02/
└── values.yaml     # spoke: spoke-02, image, replicas
```

**Structure Decision**: Keep every ArgoCD-facing artifact (Helm charts, the registry
manifests, the ApplicationSet) inside this repo — the one ArgoCD `Repository` Secret
already trusts — so no new ArgoCD repo credential is needed. Only the two pieces the
spec explicitly calls out as needing their *own* repository — the function's Go
source (FR-002) and the per-dataplane declarations (FR-006/FR-007) — become new,
standalone Gogs repositories, consumed by ArgoCD via a second/third `Repository`
Secret exactly like the platform repo's own registration in
`scripts/07-bootstrap-gitops.sh`.

## Complexity Tracking

*No entries — Constitution Check has no unjustified violations.*
