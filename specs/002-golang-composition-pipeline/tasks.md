---

description: "Task list for feature 002-golang-composition-pipeline"
---

# Tasks: Golang Composition Function Pipeline (Registry + Helm + Dataplanes Repo)

**Input**: Design documents from `/specs/002-golang-composition-pipeline/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md (all present)

**Tests**: This is an infra/GitOps lab with no automated test suite (consistent with
feature 001) — verification tasks are manual/scripted `kubectl`/`curl` checks drawn
from `quickstart.md`, not unit/integration test-writing tasks.

**Organization**: Tasks are grouped by user story (US1/US2/US3, priorities from
spec.md) after a Setup + Foundational phase.

## Format: `[ID] [P?] [Story] Description`

## Path Conventions

- Platform repo (this checkout): `registry/`, `charts/`, `gitops/apps/`, `scripts/`
- Two new standalone repos, authored in local working copies **outside** this
  checkout and pushed to Gogs only: `../dataplane-function/`, `../dataplanes/`

---

## Phase 1: Setup

**Purpose**: Scaffolding for all new artifacts, no cluster changes yet.

- [ ] T001 [P] Create `registry/` directory in this repo for the private registry's manifests
- [ ] T002 [P] Create `charts/dataplane-baseline/`, `charts/dataplane-advanced/`, `charts/dataplane-instance/` directories with `Chart.yaml` stubs (`apiVersion: v2`, `type: application`)
- [ ] T003 [P] Create local working copy `../dataplane-function/` (`git init`, no remote yet) for the Composition Function's Go source
- [ ] T004 [P] Create local working copy `../dataplanes/` (`git init`, no remote yet) for the dataplane instance declarations

**Checkpoint**: Directory scaffolding exists; nothing deployed yet.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The private registry, the Composition Function's first image, and the
Helm-packaging migration of the *existing* baseline Composition — all required
before any user story can be demonstrated, since US1 needs a working registry +
function image, and the constitution amendment requires the baseline Composition to
already be Helm-delivered.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T005 Write `registry/namespace.yaml`, `registry/pvc.yaml` (registry blob storage) in this repo
- [ ] T006 Write `registry/deployment.yaml` (`registry:2` / `distribution/distribution`, hub-local, no auth) in this repo
- [ ] T007 Write `registry/service.yaml` exposing the registry at `registry.registry.svc.cluster.local:5000` in this repo
- [ ] T008 Write `registry/ingress.yaml` for `registry.127-0-0-1.nip.io` reusing the existing Traefik + `lab-ca-issuer` cert-manager pattern (see `gitops/argocd/gogs-ingress.yaml` for the reference shape) in this repo
- [ ] T009 Create `gitops/apps/registry.yaml` ArgoCD Application (`directory` source → `registry/`, sync-wave `"0"`, same wave as Gogs/Crossplane core) in this repo
- [ ] T010 Apply/sync `registry` via ArgoCD and verify it is `Synced`/`Healthy` and reachable both in-cluster and via `https://registry.127-0-0-1.nip.io/v2/`
- [ ] T011 [P] Write `../dataplane-function/go.mod` and `../dataplane-function/main.go` implementing the `function-sdk-go` `RunFunction` server per data-model.md's Composition Function entity (composes Namespace/ConfigMap/Deployment-with-requests-limits/Service as `provider-kubernetes` `Object`s, standardized labels/annotations, `spec.parameters.spoke` → `providerConfigRef.name`)
- [ ] T012 [P] Write `../dataplane-function/Dockerfile` (multi-stage Go build → distroless runtime image) in the function repo
- [ ] T013 Build and push `dataplane-function:v0.1.0` to `registry.127-0-0-1.nip.io` and confirm it is pullable at `registry.registry.svc.cluster.local:5000/dataplane-function:v0.1.0` from inside the hub
- [ ] T014 [P] Move `crossplane/compositions/xrd-dataplane.yaml` content into `charts/dataplane-baseline/templates/xrd-dataplane.yaml` unchanged (byte-for-byte rendering) in this repo
- [ ] T015 [P] Move `crossplane/compositions/composition-dataplane-k8s.yaml` content into `charts/dataplane-baseline/templates/composition-dataplane-k8s.yaml` unchanged in this repo
- [ ] T016 Update `gitops/apps/crossplane-compositions.yaml` source from `directory`/`path: crossplane/compositions` to `helm`/`path: charts/dataplane-baseline` in this repo, keeping its existing sync-wave
- [ ] T017 Sync and verify `crossplane-compositions` is `Synced`/`Healthy` post-migration, and that feature 001's existing example claims (`demo-01`, `demo-02` from `crossplane/examples/`) still report `Ready: "True"` (non-regression, spec FR-010)
- [ ] T018 Write `scripts/11-push-function-and-dataplanes-repos.sh` in this repo: creates the `dataplane-function` and `dataplanes` Gogs repos (same API-based pattern as `scripts/05-push-to-gogs.sh`), pushes each local working copy's initial content, and registers both as ArgoCD `Repository` Secrets (same pattern as `scripts/07-bootstrap-gitops.sh`)

**Checkpoint**: Registry live and holding a function image; baseline Composition now
Helm-delivered and verified non-regressed; both new Gogs repos exist and are
registered with ArgoCD. User story implementation can now begin.

---

## Phase 3: User Story 1 - Provision a dataplane through the advanced composition by declaring it in Git (Priority: P1) 🎯 MVP

**Goal**: An operator adds a directory + `values.yaml` to the `dataplanes` repo and
the corresponding richer dataplane appears in the chosen spoke, with no direct
cluster command.

**Independent Test**: Add `demo-01/values.yaml` (spoke-01) and `demo-02/values.yaml`
(spoke-02) to the `dataplanes` repo, push, and confirm both spokes end up with the
richer resource set (Namespace, ConfigMap, Deployment with resource limits/labels,
Service) — see `quickstart.md` Story 1.

### Implementation for User Story 1

- [ ] T019 [US1] Write `charts/dataplane-advanced/templates/xrd-dataplane-advanced.yaml` (`CompositeResourceDefinition` `xdataplaneadvanceds.lab.example.org`, claim `AdvancedDataPlane`, schema per data-model.md: `spoke` required, `image`/`replicas`/`config` optional with defaults)
- [ ] T020 [US1] Write `charts/dataplane-advanced/templates/function.yaml` (Crossplane `Function` resource, `spec.package` from `.Values.function.image`) and set the default in `charts/dataplane-advanced/values.yaml` to `registry.registry.svc.cluster.local:5000/dataplane-function:v0.1.0`
- [ ] T021 [US1] Write `charts/dataplane-advanced/templates/composition-dataplane-advanced.yaml` (`Composition` with `spec.mode: Pipeline`, single pipeline step referencing the `Function` from T020, `compositeTypeRef` pointing at the XRD from T019)
- [ ] T022 [US1] Create `gitops/apps/crossplane-compositions-advanced.yaml` ArgoCD Application (`helm` source → `charts/dataplane-advanced`, sync-wave `"1"`, same wave as the existing `crossplane-compositions`) in this repo
- [ ] T023 [US1] Write `charts/dataplane-instance/values.yaml` (schema: `spoke`, `image`, `replicas`, `config` — mirrors `contracts/dataplane-instance-values.md`) and `charts/dataplane-instance/templates/claim.yaml` (renders one `AdvancedDataPlane` claim named after `.Release.Name`) in this repo
- [ ] T024 [US1] Write `gitops/apps/dataplanes-appset.yaml` (`ApplicationSet`, `git` generator in `directories` mode against the `dataplanes` Gogs repo, multi-source template: source 1 = this repo's `charts/dataplane-instance`, source 2 = the matching directory in `dataplanes` referenced as `$values` with `helm.valueFiles: ['$values/{{path.basename}}/values.yaml']`) in this repo
- [ ] T025 [US1] [P] Add `../dataplane-function/../dataplanes/demo-01/values.yaml` (`spoke: spoke-01`) to the `dataplanes` working copy per `contracts/dataplane-instance-values.md`
- [ ] T026 [US1] [P] Add `../dataplanes/demo-02/values.yaml` (`spoke: spoke-02`) to the `dataplanes` working copy
- [ ] T027 [US1] Run `scripts/11-push-function-and-dataplanes-repos.sh` (from Phase 2) to push both repos' initial content now that they have real content, and commit+push `charts/`, `registry/`, and `gitops/apps/*` changes to this repo's `origin` and `gogs` remotes
- [ ] T028 [US1] Sync and verify `crossplane-compositions-advanced` and the `dataplanes` `ApplicationSet`-generated Applications (`dataplane-demo-01`, `dataplane-demo-02`) are all `Synced`/`Healthy`
- [ ] T029 [US1] Run `quickstart.md` Story 1 verification end-to-end: both `AdvancedDataPlane` claims reach `Ready: "True"`, and `spoke-01`/`spoke-02` each show the richer resource set only for their own dataplane (isolation preserved)

**Checkpoint**: User Story 1 fully functional — this is the MVP. Stop here and
demo/validate before continuing if time-constrained.

---

## Phase 4: User Story 2 - Build and host the composition function without any external dependency (Priority: P2)

**Goal**: Publish a changed function image to the internal registry and roll it out
purely via a Helm chart release — no manifest applied by hand, nothing pulled from
outside the lab.

**Independent Test**: Change `main.go`, build+push a new tag, bump
`charts/dataplane-advanced/values.yaml`'s image tag, and confirm the running
`Function` resource updates via ArgoCD's Helm sync alone — see `quickstart.md`
Story 2.

### Implementation for User Story 2

- [ ] T030 [US2] Write `scripts/12-build-push-function.sh` in this repo: a reusable `docker build && docker push` wrapper against `../dataplane-function`, parameterized by image tag, for republishing after source changes
- [ ] T031 [US2] Make one real, observable change to `../dataplane-function/main.go` (e.g. add a new standardized annotation), build+push as `v0.2.0` via T030
- [ ] T032 [US2] Bump `charts/dataplane-advanced/values.yaml`'s `function.image` tag to `v0.2.0`, commit and push to both `origin` and `gogs` remotes of this repo
- [ ] T033 [US2] Run `quickstart.md` Story 2 verification: `crossplane-compositions-advanced` Application shows a new Helm revision, and `kubectl get function.pkg.crossplane.io dataplane-function -o jsonpath='{.spec.package}'` prints the `:v0.2.0` tag, with no manifest applied by hand outside the chart release

**Checkpoint**: User Stories 1 AND 2 both work independently.

---

## Phase 5: User Story 3 - Manage many dataplanes independently through the same repository (Priority: P3)

**Goal**: Adding, editing, or removing one dataplane's directory affects only that
dataplane — no shared file changes, regardless of how many dataplanes already exist.

**Independent Test**: With `demo-01`/`demo-02` already provisioned (US1), add
`demo-03`, then remove `demo-02`, and confirm `demo-01`/`demo-03` are unaffected at
every step — see `quickstart.md` Story 3.

### Implementation for User Story 3

- [ ] T034 [US3] [P] Add `../dataplanes/demo-03/values.yaml` (`spoke: spoke-01`, distinct `replicas`) to the `dataplanes` working copy, commit and push to the `dataplanes` Gogs repo only (no changes to `dataplanes-appset.yaml` or any chart)
- [ ] T035 [US3] Verify the `ApplicationSet` generated `dataplane-demo-03` automatically and that it reached `Ready`, while `demo-01`/`demo-02` remain unaffected
- [ ] T036 [US3] Remove the `demo-02/` directory from the `dataplanes` working copy, commit and push
- [ ] T037 [US3] Run `quickstart.md` Story 3 verification: `dataplane-demo-02` Application and its spoke resources are pruned, while `demo-01` and `demo-03` keep running unaffected with zero changes to any shared file

**Checkpoint**: All three user stories independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and full-suite validation across all stories.

- [ ] T038 [P] Update `README.md` with: the private registry's access instructions, the two new Gogs repos and what each holds, how to add/remove a dataplane, and the fact that Compositions are now Helm-delivered (mirroring the existing "Estrutura" and "Acessar as UIs" sections' style)
- [ ] T039 Run the full `quickstart.md` (Prerequisites through Cleanup, all three stories plus the non-regression check) end-to-end in one pass and confirm every "Expected outcome" holds
- [ ] T040 Confirm every spec.md Success Criterion (SC-001 through SC-007) against the final state, and note any gap explicitly rather than silently marking it done

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (US1 needs the registry + function image + Helm-migrated baseline + both Gogs repos registered).
- **User Story 1 (Phase 3)**: Depends on Foundational only. This is the MVP.
- **User Story 2 (Phase 4)**: Depends on Foundational + US1 (needs a first function image and the `dataplane-advanced` chart already installed to have something to upgrade).
- **User Story 3 (Phase 5)**: Depends on Foundational + US1 (needs the `ApplicationSet` and at least the two US1 example dataplanes already provisioned to demonstrate independence against).
- **Polish (Phase 6)**: Depends on whichever of US1/US2/US3 were completed.

### Parallel Opportunities

- T001–T004 (Setup) are all `[P]` — different directories, no dependency.
- T011/T012 (function source + Dockerfile) and T014/T015 (baseline chart template moves) are `[P]` — independent files.
- T025/T026 (demo-01/demo-02 values files) are `[P]` — independent files, same directory tree but no shared file.
- T034 (US3's demo-03) is `[P]` relative to any remaining US2 task — different repo/files entirely.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (Setup) and Phase 2 (Foundational) — registry up, function image
   published once, baseline Composition Helm-migrated and verified non-regressed,
   both new Gogs repos created.
2. Complete Phase 3 (User Story 1) — two example dataplanes provisioned end-to-end
   through the advanced composition.
3. **STOP and VALIDATE** against `quickstart.md` Story 1 before continuing.

### Incremental Delivery

1. Setup + Foundational → registry/function/baseline-chart/repos ready.
2. User Story 1 → demo-01/demo-02 provisioned via the advanced composition (MVP).
3. User Story 2 → prove the function/chart can be updated and rolled out via Helm
   alone.
4. User Story 3 → prove the dataplanes repo scales to N instances independently.
5. Polish → docs + full quickstart pass + Success Criteria review.
