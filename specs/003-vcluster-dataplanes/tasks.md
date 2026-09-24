---

description: "Task list for feature 003-vcluster-dataplanes"
---

# Tasks: vcluster-Based Dataplane Clusters (XDataPlane Redefined)

**Input**: Design documents from `/specs/003-vcluster-dataplanes/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md (all present)

**Tests**: Infra/GitOps lab, no automated test suite (consistent with features 001/002)
— verification tasks are manual/scripted `kubectl`/`curl` checks drawn from
`quickstart.md`, not unit/integration test-writing tasks.

**Organization**: Tasks are grouped by user story (US1/US2/US3, priorities from
spec.md) after a Setup + Foundational phase. US1 provisions a throwaway `spoke-03`
that stays alive through US1/US2 and is torn down as US3's own verification (avoids
creating and destroying a demo spoke twice).

## Format: `[ID] [P?] [Story] Description`

## Path Conventions

- Platform repo (this checkout): `compositions/dataplane-cluster/`,
  `crossplane/providers/`, `crossplane/config/`, `charts/dataplane-cluster/`,
  `gitops/apps/`, `scripts/`, `docs/`
- The `dataplanes` repo (separate, local working copy at `../dataplanes/`):
  `dataplanes/spoke-03.yaml` (temporary, added and removed by this feature)

---

## Phase 1: Setup

**Purpose**: Scaffolding for all new artifacts, no cluster changes yet.

- [x] T001 [P] Create `compositions/dataplane-cluster/chart/templates/` directory with a `Chart.yaml` stub (`apiVersion: v2`, `type: application`) — replaces `compositions/dataplane-baseline/`
- [x] T002 [P] Create `compositions/dataplane-cluster/examples/` directory for a manual-test claim
- [x] T003 [P] Create `crossplane/providers/provider-helm.yaml` and `crossplane/config/providerconfig-helm-hub.yaml` as empty files to be filled in Phase 2

**Checkpoint**: Directory scaffolding exists; nothing deployed yet.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: `provider-helm` installed and the redefined `XDataPlane`
Composition/XRD delivering a working `DataPlane` claim mechanism — required before
any user story can be demonstrated.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T004 Write `crossplane/providers/provider-helm.yaml`: `Provider` package (`xpkg.upbound.io/crossplane-contrib/provider-helm`, pin a current stable version) plus an aggregated `ClusterRole` (label `rbac.crossplane.io/aggregate-to-crossplane: "true"`, same mechanism as `provider-kubernetes-secrets`) granting the permissions the vcluster chart's resources need (`apps`, `core`, `rbac.authorization.k8s.io` at minimum — finalize exact rule list empirically per research.md #5) and a `ClusterRoleBinding` giving `provider-helm`'s own ServiceAccount that role (for `InjectedIdentity` to work, the provider's SA itself needs these permissions, not just an aggregated role visible to it — verify which is actually required during implementation)
- [x] T005 Write `crossplane/config/providerconfig-helm-hub.yaml`: `ProviderConfig` (`helm.crossplane.io/v1beta1`), `credentials.source: InjectedIdentity`
- [x] T006 Sync `crossplane-providers`; verify `provider-helm` reports `INSTALLED: True, HEALTHY: True` (`kubectl --context k3d-hub get provider.pkg.crossplane.io provider-helm`)
- [x] T007 Sync `crossplane-config`; verify `kubectl --context k3d-hub get providerconfig.helm.crossplane.io hub` exists
- [x] T008 Write `compositions/dataplane-cluster/chart/templates/xrd-dataplane.yaml`: `CompositeResourceDefinition` `xdataplanes.lab.example.org`, `names.kind: XDataPlane`, `claimNames.kind: DataPlane` (same names as feature 001's retired XRD — see contracts/dataplane-claim.md for the schema: `spec.parameters.kubernetesVersion` optional, no required parameters)
- [x] T009 Write `compositions/dataplane-cluster/chart/templates/composition-dataplane-cluster.yaml`: classic Patch-and-Transform `Composition` composing one `helm.crossplane.io/v1beta1` `Release` — chart repo/name/version from `values.yaml`, release name and namespace both patched from the claim's `metadata.name`, values overriding `exportKubeConfig.server` to `https://<name>.<name>.svc.cluster.local:443` (research.md #2), and `kubernetesVersion` patched through only when `spec.parameters.kubernetesVersion` is set
- [x] T010 Write `compositions/dataplane-cluster/chart/values.yaml` (default vcluster chart repo URL + version)
- [x] T011 Write `compositions/dataplane-cluster/examples/claim-dataplane.yaml` (a minimal `DataPlane` claim, name `dataplane-cluster-test`, for `make test`) and `compositions/dataplane-cluster/Makefile` (dev/build/push/test, same shape as the other Compositions' Makefiles — `push`/`build` are Helm-lint/template no-ops here, no image involved)
- [x] T012 Delete `compositions/dataplane-baseline/` entirely (chart, Makefile) and its `crossplane/examples/claim-dataplane-spoke-01.yaml`/`claim-dataplane-spoke-02.yaml` — feature 001's baseline meaning is retired per FR-001
- [x] T013 Update `gitops/apps/crossplane-compositions.yaml`: `path: compositions/dataplane-cluster/chart` (was `compositions/dataplane-baseline/chart`)
- [x] T014 Update root `Makefile`'s `COMPOSITIONS :=` list: replace `dataplane-baseline` with `dataplane-cluster`
- [x] T015 Sync `crossplane-compositions`; verify `Synced`/`Healthy` and `kubectl --context k3d-hub get xrd xdataplanes.lab.example.org` exists with `claimNames.kind: DataPlane`
- [x] T016 Apply `compositions/dataplane-cluster/examples/claim-dataplane.yaml` directly (`kubectl apply`, not yet via Git/ArgoCD) as a first smoke test; confirm it reaches `Ready` and a `Release` exists (`kubectl --context k3d-hub get release.helm.crossplane.io dataplane-cluster-test`); then delete it — this is the Foundational-phase proof the mechanism works at all, before wiring it into the `dataplanes` repo flow in US1

**Checkpoint**: A `DataPlane` claim applied by hand produces a working vcluster. No Git-driven flow yet.

---

## Phase 3: User Story 1 - Provision a new dataplane cluster by submitting a claim (Priority: P1) 🎯 MVP

**Goal**: Adding a file to the `dataplanes` repo is sufficient to bring a new
vcluster-backed spoke into existence, with no k3d/Docker command.

**Independent Test**: Add `dataplanes/spoke-03.yaml`, push, and confirm — without
running k3d/Docker — a `Ready` `DataPlane` claim, a running vcluster in the hub, and
(after running the existing registration script) a `ProviderConfig` and ArgoCD
Cluster for `spoke-03`.

- [x] T018 [US1] Write `charts/dataplane-cluster/templates/dataplane-claim.yaml` in the platform repo: always renders exactly one `DataPlane` claim named `{{ .Values.cluster }}`, regardless of whether `charts:`/`compositions:` are empty (data-model.md, research.md #7) — rendered directly by the wrapper chart itself, **not** routed through `_helpers.tpl`'s composition-name→chart-path map used by `compositions:` entries, since the cluster claim isn't one more workload composition, it's the spoke itself
- [x] T019 [US1] Commit and push the platform repo change from T018; force-refresh `root-app-of-apps`/the `dataplanes` `ApplicationSet` if ArgoCD's layered caches don't pick it up within a few minutes (known issue, see quickstart.md Troubleshooting)
- [x] T020 [US1] In the local `dataplanes` working copy, add `dataplanes/spoke-03.yaml` with `cluster: spoke-03`, `charts: []`, `compositions: []`; commit and push to the `gogs` remote
- [x] T021 [US1] Verify `dataplane-spoke-03` wrapper `Application` and its child `Application` for the `DataPlane` claim are `Synced`/`Healthy`; verify `kubectl --context k3d-hub get dataplane spoke-03` reaches `Ready` within 5 minutes (SC-001)
- [x] T022 [US1] Verify the vcluster's pods are running in the hub (`kubectl --context k3d-hub -n spoke-03 get pods`) and its kubeconfig Secret exists (`kubectl --context k3d-hub -n spoke-03 get secrets`)
- [x] T023 [US1] Write `crossplane/config/providerconfig-spoke-03.yaml` (same shape as `providerconfig-spoke-01.yaml`, `secretRef` pointing at `spoke-03`'s vcluster-generated Secret per research.md #4); commit, push, sync `crossplane-config`
- [x] T024 [US1] Update `scripts/16-register-argocd-clusters.sh` to read each spoke's vcluster-generated kubeconfig Secret directly (namespace = spoke name) instead of a `.secrets/<spoke>.kubeconfig` local file (research.md #4); run it and confirm `spoke-03` appears via `GET /api/v1/clusters` on the ArgoCD API (SC-001)

**Checkpoint**: User Story 1 fully functional and independently verifiable — a brand-new dataplane cluster exists from one Git-committed file, zero k3d/Docker commands. `spoke-03` stays running for US3's teardown verification.

---

## Phase 4: User Story 2 - Everything that already targets a spoke keeps working unmodified (Priority: P2)

**Goal**: Migrate `spoke-01`/`spoke-02` from real k3d clusters to vclusters without
editing any existing `AdvancedDataPlane` claim, `dataplanes/<spoke>.yaml` file, or
chart.

**Independent Test**: After migration, `adv-01`'s claim and `dataplanes/spoke-01.yaml`'s `hello` chart entry are both still `Ready`/`Synced`+`Healthy`, with zero
edits to either.

- [x] T025 [US2] Confirm `dataplane-spoke-01` and `dataplane-spoke-02` wrapper Applications (already existing from ADR-029) automatically pick up T018's new template and each produce a `Ready` `DataPlane` claim (`spoke-01`, `spoke-02`) with **no edit** to `dataplanes/spoke-01.yaml`/`dataplanes/spoke-02.yaml` (FR-005)
- [x] T026 [US2] Verify both vclusters come up in the hub (`kubectl --context k3d-hub -n spoke-01 get pods`, same for `spoke-02`) alongside the still-running real k3d `spoke-01`/`spoke-02` clusters (controlled cutover window)
- [x] T027 [US2] Update `crossplane/config/providerconfig-spoke-01.yaml` and `providerconfig-spoke-02.yaml`: `secretRef` now points at each spoke's vcluster-generated Secret (namespace = spoke name) instead of `crossplane-system/<spoke>-kubeconfig`; commit, push, sync `crossplane-config`
- [x] T028 [US2] Re-run the updated `scripts/16-register-argocd-clusters.sh` (T024); confirm the ArgoCD Cluster entries for `spoke-01`/`spoke-02` now report the vcluster's in-cluster Service address, not the old Docker container IP
- [x] T029 [US2] Verify `AdvancedDataPlane` claims `adv-01`/`adv-03` reconcile against the new vclusters with **no edit to either claim** — `selfHeal` recreates their composed resources inside the vcluster; confirm `Ready: "True"` and the resources exist (`kubectl --context k3d-hub -n spoke-01 exec ... -- kubectl get ns dp-adv-01 deploy,svc,cm`, per quickstart.md)
- [x] T030 [US2] Verify `dataplanes/spoke-01.yaml`'s `hello` chart entry's Application (`dataplane-spoke-01-hello`) stays `Synced`/`Healthy` against the vcluster, with **no edit** to `dataplanes/spoke-01.yaml` or `charts/hello/` (FR-005)
- [x] T031 [US2] Retire `scripts/03-register-spokes.sh` (delete the file; its job — generating a spoke kubeconfig Secret — is now done by the vcluster chart itself) and remove its call from `scripts/00-up.sh`
- [x] T032 [US2] Update `scripts/02-create-clusters.sh` to create only the `hub` k3d cluster — remove `spoke-01`/`spoke-02` creation, the shared-network wiring, and the `--tls-san` logic (Technology Constraints, v1.2.0)
- [x] T033 [US2] Decommission the old real k3d clusters: `k3d cluster delete spoke-01 spoke-02`; confirm `spoke-01`/`spoke-02` workloads are still healthy afterward (proves the vclusters, not the old k3d clusters, were actually serving them)
- [x] T034 [US2] Update `README.md`'s "Passo a passo" and "Estrutura" sections: remove `scripts/03-register-spokes.sh` from the setup sequence, note only `hub` is a real k3d cluster, spokes are vclusters created via `DataPlane` claims

**Checkpoint**: User Story 2 fully functional — `spoke-01`/`spoke-02` are vclusters, every pre-existing spoke-dependent resource still works, unmodified, and the old real k3d spoke clusters no longer exist.

---

## Phase 5: User Story 3 - Remove a dataplane cluster by deleting its claim (Priority: P3)

**Goal**: Deleting a `DataPlane` claim tears down its vcluster cleanly.

**Independent Test**: Delete `spoke-03`'s claim (created in US1) and confirm its
vcluster and namespace are gone.

- [x] T035 [US3] Remove `dataplanes/spoke-03.yaml` from the `dataplanes` repo, commit and push; confirm the `dataplane-spoke-03` wrapper Application (and its `DataPlane`-claim child) is pruned by the `dataplanes` `ApplicationSet`
- [x] T036 [US3] Confirm the `spoke-03` claim's composed `Release` is deleted and the vcluster's namespace/pods/kubeconfig Secret are gone from the hub within 5 minutes (SC-003)
- [x] T037 [US3] Manually remove `spoke-03`'s now-stale `ProviderConfig` (`crossplane/config/providerconfig-spoke-03.yaml`, delete file + `kubectl delete`) and its ArgoCD Cluster Secret (`kubectl --context k3d-hub -n argocd delete secret cluster-spoke-03`) — confirmed as a manual step, not automated, per contracts/dataplane-claim.md
- [x] T038 [US3] Confirm zero orphaned resources remain for `spoke-03` anywhere in the hub (SC-003)

**Checkpoint**: All three user stories independently verified. Feature functionally complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation consistency across the whole repo, matching this
project's established practice of keeping `docs/` and `README.md` truthful to
current state.

- [ ] T039 [P] Update `docs/architecture.md`: hub is the only real k3d cluster; spokes are vclusters; `XDataPlane`/`DataPlane` redefined; mermaid diagram and the app-of-apps table updated
- [ ] T040 [P] Update `docs/compositions.md`: replace the `dataplane-baseline` section with `dataplane-cluster` (its new purpose, schema, `provider-helm` dependency); note feature 001's original meaning is retired
- [ ] T041 [P] Update `docs/gitops-workflow.md`: the `dataplanes` `ApplicationSet`/wrapper-chart section now also describes the always-rendered `DataPlane` claim child
- [ ] T042 [P] Add ADR(s) to `docs/decisions.md` documenting: the vcluster-vs-real-k3d decision, the `provider-helm` choice, the `XDataPlane` name-reuse/retirement decision, and any real issues hit during implementation (RBAC, kubeconfig Secret shape/key, TLS) — following this project's existing ADR format, only for what was actually encountered, not hypothetical
- [ ] T043 Update `docs/README.md`'s ADR entry count to match the final number added in T042
- [ ] T044 Final full health check: every ArgoCD `Application` `Synced`/`Healthy`; both migrated spokes and `spoke-03`'s teardown all re-verified in one pass; commit and push everything (platform repo to `origin`+`gogs`, `dataplanes` repo to `gogs`)

---

## Dependencies & Execution Order

- **Setup (T001-T003)**: No dependencies — can start immediately, all parallelizable.
- **Foundational (T004-T016)**: Depends on Setup. **Blocks all user stories.**
- **User Story 1 (T018-T024)**: Depends on Foundational. Delivers the MVP (a new
  dataplane cluster from Git alone).
- **User Story 2 (T025-T034)**: Depends on Foundational and on T018 (US1's
  wrapper-chart template addition) actually existing and working, since migrating
  `spoke-01`/`spoke-02` relies on the exact same mechanism US1 proved with
  `spoke-03`. Not independently startable before US1's T018-T019 land.
- **User Story 3 (T035-T038)**: Depends on `spoke-03` existing and registered
  (US1's output). Can run any time after US1, independent of US2 (US2 migrates
  different spokes).
- **Polish (T039-T044)**: Depends on all user stories being complete.

## Parallel Execution Examples

```text
# Setup phase — all independent:
T001, T002, T003

# Foundational — provider-helm and the Composition are independent tracks until sync:
T004, T005 (provider-helm track) can run alongside T008, T009, T010, T011 (Composition track)

# Polish — all independent doc files:
T039, T040, T041, T042
```

## Implementation Strategy

**MVP first**: Setup → Foundational → User Story 1 (T001-T024) delivers and proves
the whole new mechanism (a claim brings a vcluster to life) without touching the two
production spokes at all — the lowest-risk slice, and the one to get right before
migrating anything real.

**Incremental delivery**: US2 (the actual migration of `spoke-01`/`spoke-02`) is the
highest-risk phase — it changes what two already-relied-upon spokes are backed by
while live resources depend on them. Do it only after US1 is fully verified. US3
(teardown) reuses US1's `spoke-03` and can run before or after US2 without
interference.
