# Implementation Plan: Hub-and-Spoke Dataplane Provisioning

**Branch**: `001-dataplane-provisioning` | **Date**: 2026-09-18 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-dataplane-provisioning/spec.md`

**Note**: This plan documents retroactively a feature already implemented under
`crossplane/`, `gitops/`, and `bootstrap/`. It exists so the design is traceable
through Spec Kit and so future changes to this feature go through
`/speckit-specify` → `/speckit-plan` → `/speckit-tasks` rather than ad hoc edits.

## Summary

An operator creates a `DataPlane` claim in the hub cluster naming a target spoke
(`spoke-01` or `spoke-02`) and optional workload parameters (image, replica count).
Crossplane, running only in the hub, resolves the claim through the `XDataPlane`
Composition and uses `provider-kubernetes` with the `ProviderConfig` matching the
named spoke to create a `Namespace`, `Deployment`, and `Service` directly inside that
spoke's API server. No Crossplane component or controller runs on any spoke.

## Technical Context

**Language/Version**: N/A — declarative Kubernetes YAML (Crossplane XRD/Composition,
ArgoCD Application) plus POSIX shell for one-time bootstrap automation (`scripts/`).

**Primary Dependencies**: Crossplane v1.20.13 (classic Composition /
Patch-and-Transform, not v2 namespaced XRs), `provider-kubernetes` v1.3.1
(crossplane-contrib), ArgoCD (stable channel), k3d v5.x, Gogs 0.14.

**Storage**: Kubernetes `Secret` objects (spoke kubeconfigs, ArgoCD repository
credentials) in the hub's `crossplane-system`/`argocd` namespaces; no dedicated
database. Gogs persists its own SQLite DB + git repos on a `PersistentVolumeClaim`.

**Testing**: No automated test suite — this is an infra lab. Validation is manual:
apply the example claims (`crossplane/examples/`) against the hub and confirm the
expected `Namespace`/`Deployment`/`Service` exist in the target spoke via
`kubectl --context k3d-spoke-0N`. See `quickstart.md`.

**Target Platform**: Three k3d (k3s-in-Docker) clusters — `hub`, `spoke-01`,
`spoke-02` — sharing one Docker network (`hublab`), running on a local dev machine.

**Project Type**: Infrastructure / GitOps platform configuration (not an application
with its own runtime) — a Crossplane control-plane feature plus its ArgoCD delivery
wiring.

**Performance Goals**: See spec SC-001 (workload observable in target spoke within 2
minutes of claim creation, image already cached).

**Constraints**: An operator or any platform component MUST reach a spoke only
through `provider-kubernetes` + `ProviderConfig` from the hub — never directly
(constitution Principle II). All of the above except the out-of-band kubeconfig
`Secret`s MUST be Git-tracked and ArgoCD-reconciled (constitution Principle I).

**Scale/Scope**: 2 spokes registered today; the Composition/XRD MUST NOT need to
change to add a 3rd (spec SC-004).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. GitOps-Only Changes | PASS | `crossplane/{providers,config,compositions}/` and `gitops/apps/crossplane*.yaml` are all reconciled by ArgoCD. **Scope note**: the example *claims* under `crossplane/examples/` are operator-triggered test invocations, not continuously-reconciled platform state, and are intentionally applied manually (documented in `quickstart.md`) — this mirrors how a test suite is invoked, not how the platform itself is deployed, so it does not violate the principle. |
| II. Hub-and-Spoke Isolation | PASS | Only `provider-kubernetes` + `ProviderConfig` (named per spoke) reach spokes; no controller runs there; spoke selection is data (`spec.parameters.spoke`), never a hardcoded endpoint. |
| III. App-of-Apps Structure | PASS | Delivered via existing `gitops/apps/crossplane-providers.yaml` (wave 1) and `gitops/apps/crossplane-compositions.yaml` (wave 1); no new Application needed for this feature. |
| IV. Composable, Testable Compositions | PASS | Verified end-to-end on 2026-09-18: both example claims (`demo-01`→`spoke-01`, `demo-02`→`spoke-02`) reached `SYNCED=True`/`READY=True` within ~10s, produced the expected `dp-<claim-name>` namespace/Deployment/Service in the correct spoke only (cross-spoke isolation confirmed), and `demo-02`'s `replicas: 2` override applied correctly. See `quickstart.md`. |
| V. Secrets Never Committed | PASS | `spoke-0N-kubeconfig` Secrets are created by `scripts/03-register-spokes.sh` directly in-cluster; only `secretRef` names are committed. |

No unjustified violations — no Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/001-dataplane-provisioning/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md         # Phase 1 output
├── quickstart.md         # Phase 1 output
├── contracts/
│   └── dataplane-claim.md
└── tasks.md              # Phase 2 output (/speckit-tasks — not created by /speckit-plan)
```

### Source Code (repository root)

This feature has no application source tree (no `src/`/`tests/`) — it is entirely
declarative platform configuration. The relevant existing paths are:

```text
crossplane/
├── providers/provider-kubernetes.yaml        # Provider + RBAC to read spoke kubeconfig secrets
├── config/
│   ├── providerconfig-spoke-01.yaml          # Spoke registration (name == claim's spec.parameters.spoke)
│   └── providerconfig-spoke-02.yaml
├── compositions/
│   ├── xrd-dataplane.yaml                    # CompositeResourceDefinition: XDataPlane / claim DataPlane
│   └── composition-dataplane-k8s.yaml        # Namespace + Deployment + Service via provider-kubernetes Objects
└── examples/
    ├── claim-dataplane-spoke-01.yaml         # Example DataPlane claim targeting spoke-01
    └── claim-dataplane-spoke-02.yaml         # Example DataPlane claim targeting spoke-02

gitops/apps/
├── crossplane-providers.yaml                 # ArgoCD Application, sync-wave 1
└── crossplane-compositions.yaml              # ArgoCD Application, sync-wave 1

scripts/
├── 03-register-spokes.sh                     # Creates the out-of-band kubeconfig Secrets
└── 02-create-clusters.sh                     # Creates hub/spoke-01/spoke-02 on the shared network
```

**Structure Decision**: Reuse the existing repository layout as-is (Option: none of
the template's app/library options apply). This feature only adds Spec Kit
documentation under `specs/001-dataplane-provisioning/`; no source directories are
created or restructured.

## Complexity Tracking

*No entries — Constitution Check has no unjustified violations.*
