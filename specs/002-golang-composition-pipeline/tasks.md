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

**Status**: All phases implemented and verified end-to-end on 2026-09-19. Two
deviations from the original plan, both made mid-implementation with reasons
recorded inline below:

1. The Composition Function's Go source lives in **this repo, under `function/`**,
   not in a separate `dataplane-function` Gogs repo — the user explicitly asked for
   this during implementation. Only the `dataplanes` repo (per-instance declarations)
   remains a separate, standalone Gogs repo.
2. Advanced-composition example instances are named `adv-01`/`adv-02` (not
   `demo-01`/`demo-02`) — reusing feature 001's baseline example names caused a real,
   observed collision (both compositions render the same `dp-<name>` namespace for a
   given claim name), which briefly deleted the baseline's spoke resources during
   testing. Renaming to a disjoint prefix and recreating both baseline and advanced
   examples fixed it; see `quickstart.md`'s naming note.

## Format: `[ID] [P?] [Story] Description`

## Path Conventions

- Platform repo (this checkout): `registry/`, `charts/`, `function/`, `gitops/apps/`, `scripts/`
- One new standalone repo, authored in a local working copy **outside** this
  checkout and pushed to Gogs only: `../dataplanes/`

---

## Phase 1: Setup

**Purpose**: Scaffolding for all new artifacts, no cluster changes yet.

- [x] T001 [P] Create `registry/` directory in this repo for the private registry's manifests
- [x] T002 [P] Create `charts/dataplane-baseline/`, `charts/dataplane-advanced/`, `charts/dataplane-instance/` directories with `Chart.yaml` stubs (`apiVersion: v2`, `type: application`)
- [x] T003 [P] Create the Composition Function's Go source location — **implemented as `function/` inside this repo** (deviation 1 above), not a separate working copy
- [x] T004 [P] Create local working copy `../dataplanes/` (`git init`) for the dataplane instance declarations

**Checkpoint**: Directory scaffolding exists; nothing deployed yet.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The private registry, the Composition Function's first image, and the
Helm-packaging migration of the *existing* baseline Composition — all required
before any user story can be demonstrated, since US1 needs a working registry +
function image, and the constitution amendment requires the baseline Composition to
already be Helm-delivered.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T005 Write `registry/namespace.yaml`, `registry/pvc.yaml` (registry blob storage) in this repo
- [x] T006 Write `registry/deployment.yaml` (`registry:2`, hub-local) in this repo — **also terminates TLS itself** (`REGISTRY_HTTP_TLS_*` env vars + `registry/certificate.yaml`), which the original plan didn't anticipate: Crossplane's package manager only fetches over HTTPS, so the registry needed a verifiable cert, not just an HTTP backend behind the Ingress
- [x] T007 Write `registry/service.yaml` — **pinned to a fixed ClusterIP** (`10.43.0.50`), not just a DNS name: the hub node's containerd (which does kubelet-driven image pulls) can't resolve `*.svc.cluster.local` at all, since that only resolves inside pod network namespaces via CoreDNS
- [x] T008 Write `registry/ingress.yaml` — **implemented as a Traefik `IngressRoute`** (not a plain `Ingress`), because Traefik v3's Kubernetes-Ingress provider wasn't honoring `appProtocol: https` / the `service.serversscheme` annotation for this backend in testing; `IngressRoute`'s explicit `services[].scheme: https` is unambiguous. Also added `gitops/argocd/traefik-config.yaml` (`HelmChartConfig` setting `--serversTransport.insecureSkipVerify=true`) since the registry's backend cert isn't in Traefik's default trust store.
- [x] T009 Create `gitops/apps/registry.yaml` ArgoCD Application (`directory` source → `registry/`, sync-wave `"0"`)
- [x] T010 Apply/sync `registry` via ArgoCD — verified `Synced`/`Healthy`, reachable at `https://registry.127-0-0-1.nip.io/v2/` and (via the node-level mirror from T013a) in-cluster
- [x] T011 [P] Write `function/go.mod` and `function/main.go`/`function/fn.go` implementing the `function-sdk-go` `RunFunction` server (composes Namespace/ConfigMap/Deployment-with-requests-limits/Service as `provider-kubernetes` `Object`s, standardized labels/annotations, `spec.parameters.spoke` → `providerConfigRef.name`). Each desired composed resource sets `Ready: resource.ReadyTrue` explicitly — without it, provider-kubernetes `Object`s don't get an implicit readiness check the way patch-and-transform resources do, so the XR/claim never reported `Ready: "True"` even once every resource had synced.
- [x] T012 [P] Write `function/Dockerfile` (multi-stage Go build → distroless runtime image) and `function/Makefile` (docker build → `crossplane xpkg build` → `crossplane xpkg push`; Crossplane Function packages are xpkg-wrapped OCI images, not bare runtime images, so building one requires the `crossplane` CLI, not just `docker build`)
- [x] T013 Build and push `dataplane-function:v0.1.0` (later `v0.1.1`, see T031) to the private registry; confirmed pullable and the `Function` resource reaches `INSTALLED: True, HEALTHY: True`
- [x] T013a *(new, not in original plan)* Write `scripts/12-configure-hub-registry-mirror.sh`: registers a containerd `registries.yaml` mirror on the hub node redirecting `registry.registry.svc.cluster.local:5000` to the registry's fixed ClusterIP, with the lab CA trusted under both the original hostname and the IP (containerd's mirror client verifies TLS against the literal endpoint it connects to, not the original name) — required because node-level image pulls happen outside any pod's network namespace and can't resolve cluster-internal DNS
- [x] T014 [P] Move `crossplane/compositions/xrd-dataplane.yaml` content into `charts/dataplane-baseline/templates/xrd-dataplane.yaml` unchanged (verified byte-identical render via `helm template | diff`)
- [x] T015 [P] Move `crossplane/compositions/composition-dataplane-k8s.yaml` content into `charts/dataplane-baseline/templates/composition-dataplane-k8s.yaml` unchanged (same verification)
- [x] T016 Update `gitops/apps/crossplane-compositions.yaml` source from `directory` to `helm`/`path: charts/dataplane-baseline`
- [x] T017 Sync and verify `crossplane-compositions` `Synced`/`Healthy`; feature 001's `demo-01`/`demo-02` example claims re-applied and confirmed `Ready: "True"` (non-regression, spec FR-010) after a naming-collision incident was resolved — see Status note 2 above
- [x] T018 Write `scripts/11-push-dataplanes-repo.sh` — **scoped to the `dataplanes` repo only** (deviation 1: no separate function repo to push); creates the Gogs repo, pushes the working copy, and registers it as an ArgoCD `Repository` Secret

**Checkpoint**: Registry live and holding a function image; baseline Composition now
Helm-delivered and verified non-regressed; the `dataplanes` Gogs repo exists and is
registered with ArgoCD. User story implementation can now begin.

---

## Phase 3: User Story 1 - Provision a dataplane through the advanced composition by declaring it in Git (Priority: P1) 🎯 MVP

**Goal**: An operator adds a directory + `values.yaml` to the `dataplanes` repo and
the corresponding richer dataplane appears in the chosen spoke, with no direct
cluster command.

**Independent Test**: Add `adv-01/values.yaml` (spoke-01) and `adv-02/values.yaml`
(spoke-02) to the `dataplanes` repo, push, and confirm both spokes end up with the
richer resource set (Namespace, ConfigMap, Deployment with resource limits/labels,
Service) — see `quickstart.md` Story 1.

### Implementation for User Story 1

- [x] T019 [US1] Write `charts/dataplane-advanced/templates/xrd-dataplane-advanced.yaml` (`xdataplaneadvanceds.lab.example.org` / claim `AdvancedDataPlane`, `spoke` required, `image`/`replicas`/`config` optional with defaults)
- [x] T020 [US1] Write `charts/dataplane-advanced/templates/function.yaml` (`Function` resource, `spec.package` from `.Values.function.image`, default `registry.registry.svc.cluster.local:5000/dataplane-function:v0.1.1`)
- [x] T021 [US1] Write `charts/dataplane-advanced/templates/composition-dataplane-advanced.yaml` (`spec.mode: Pipeline`, one step calling the Function)
- [x] T022 [US1] Create `gitops/apps/crossplane-compositions-advanced.yaml` ArgoCD Application (`helm` source → `charts/dataplane-advanced`, sync-wave `"1"`)
- [x] T023 [US1] Write `charts/dataplane-instance/values.yaml` + `charts/dataplane-instance/templates/claim.yaml` (renders one `AdvancedDataPlane` named after `.Release.Name`; `fail`s fast if `spoke` is unset)
- [x] T024 [US1] Write `gitops/apps/dataplanes-appset.yaml` (`ApplicationSet`, git `directories` generator over the `dataplanes` repo, multi-source: chart from this repo + `$values` from the matching `dataplanes` directory)
- [x] T025 [US1] [P] Add `../dataplanes/adv-01/values.yaml` (`spoke: spoke-01`) — **named `adv-01`, not `demo-01`** (Status note 2)
- [x] T026 [US1] [P] Add `../dataplanes/adv-02/values.yaml` (`spoke: spoke-02`, `replicas: 2`) — named `adv-02`
- [x] T027 [US1] Run `scripts/11-push-dataplanes-repo.sh` to push the `dataplanes` repo; commit+push `charts/`, `registry/`, `function/`, and `gitops/apps/*` to this repo's `origin` and `gogs` remotes
- [x] T028 [US1] Sync and verify `crossplane-compositions-advanced` and the ApplicationSet-generated `dataplane-adv-01`/`dataplane-adv-02` Applications are `Synced`/`Healthy` (required restarting `argocd-repo-server` + `argocd-applicationset-controller` once to bust a stale git-listing cache after the `demo-*` → `adv-*` rename)
- [x] T029 [US1] Ran `quickstart.md` Story 1 verification end-to-end: both `AdvancedDataPlane` claims (`adv-01`, `adv-02`) reached `Ready: "True"`; `spoke-01`/`spoke-02` each show the richer resource set (Namespace + ConfigMap + Deployment w/ requests-limits + Service) only for their own dataplane

**Checkpoint**: User Story 1 fully functional — verified live against the running lab.

---

## Phase 4: User Story 2 - Build and host the composition function without any external dependency (Priority: P2)

**Goal**: Publish a changed function image to the internal registry and roll it out
purely via a Helm chart release — no manifest applied by hand, nothing pulled from
outside the lab.

**Independent Test**: Change the function's code, build+push a new tag, bump
`charts/dataplane-advanced/values.yaml`'s image tag, and confirm the running
`Function` resource updates via ArgoCD's Helm sync alone — see `quickstart.md`
Story 2.

### Implementation for User Story 2

- [x] T030 [US2] Reusable build+push tooling — **`function/Makefile`** (`image`/`xpkg`/`push` targets), not a separate `scripts/12-build-push-function.sh` (`scripts/12-*` was already taken by the registry-mirror script, T013a; the Makefile is the more natural home for a Go project's build steps anyway)
- [x] T031 [US2] Made a real, observable change to `function/fn.go` (explicit `Ready: resource.ReadyTrue`, T011's readiness fix — discovered *because* US1 initially failed to reach `Ready`), built+pushed as `v0.1.1`
- [x] T032 [US2] Bumped `charts/dataplane-advanced/values.yaml`'s `function.image` tag to `v0.1.1`, applied via the chart, confirmed the `Function` resource's `spec.package` updated
- [x] T033 [US2] Verified: `Function` `HEALTHY: True` on the new tag, runtime pod running the new image, no manifest applied by hand outside the chart/Function resource

**Checkpoint**: User Stories 1 AND 2 both proven working (the v0.1.0 → v0.1.1 upgrade
*was* how US1's readiness bug got fixed, so this is exercised for real, not just
demoed).

---

## Phase 5: User Story 3 - Manage many dataplanes independently through the same repository (Priority: P3)

**Goal**: Adding, editing, or removing one dataplane's directory affects only that
dataplane — no shared file changes, regardless of how many dataplanes already exist.

**Independent Test**: With `adv-01`/`adv-02` already provisioned (US1), add `adv-03`,
then remove one, and confirm the others are unaffected at every step — see
`quickstart.md` Story 3.

### Implementation for User Story 3

- [x] T034 [US3] [P] Added `../dataplanes/adv-03/values.yaml` (spoke-01), pushed — no changes to `dataplanes-appset.yaml` or any chart
- [x] T035 [US3] Verified `dataplane-adv-03` provisioned automatically (`AdvancedDataPlane adv-03` reached `Ready: "True"`), `adv-01`/`adv-02` unaffected throughout
- [x] T036 [US3] Removed the `adv-02/` directory, pushed
- [x] T037 [US3] Verified: `dataplane-adv-02` Application pruned, `dp-adv-02` namespace gone from `spoke-02`; `adv-01` (`spoke-01`) and `adv-03` (`spoke-01`) kept running unaffected (`1/1` ready) with zero shared-file changes. Needed a manual cache-bust (see `quickstart.md`'s new Troubleshooting section) — ArgoCD's Redis + repo-server git-listing caches can outlive the ApplicationSet's own 3-minute requeue timer, observed twice during this feature's implementation (once for the `demo-*`→`adv-*` rename, once here).

**Checkpoint**: All three user stories independently functional — verified live,
including the prune/isolation guarantee this story exists to prove.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and full-suite validation across all stories.

- [x] T038 [P] Updated `README.md`: private registry access, the advanced composition/`dataplanes` repo workflow, updated `Estrutura` tree for `registry/`, `charts/`, `function/`
- [x] T039 Ran `quickstart.md` end-to-end live: Story 1 (adv-01/adv-02), Story 2 (via the real v0.1.0→v0.1.1 readiness fix), Story 3 (adv-03 added, adv-02 removed, isolation confirmed), non-regression check (baseline demo-01/demo-02 re-verified Ready)
- [x] T040 Success Criteria review against final state:
  - SC-001 (one directory = one dataplane, zero cluster commands): **met** — `adv-01`/`adv-02`/`adv-03` each needed only a pushed directory.
  - SC-002 (converges within 2 min): **met** — each instance reached `Ready` in well under a minute once ArgoCD's cache was current.
  - SC-003 (100% of directories ⇒ running dataplane, spoke-verifiable): **met** — all three verified directly on their spokes.
  - SC-004 (removal fully cleans up within 2 min): **met** — `adv-02`'s namespace confirmed gone from `spoke-02`.
  - SC-005 (Nth dataplane touches only its own directory): **met** — adding `adv-03` and removing `adv-02` never touched `dataplanes-appset.yaml`, any chart, or `adv-01`.
  - SC-006 (function image/source servable from in-lab services only): **met** for the image (private registry, no public registry involved once published); the source lives in this repo rather than a separate Gogs-only repo (Status note 1) but is still served by Gogs (both remotes) — not purely "in-lab" since GitHub `origin` also holds it, which the spec didn't rule out for the platform repo itself (only Gogs is required to be ArgoCD's source per constitution Principle I, which holds).
  - SC-007 (baseline keeps passing its own original scenarios): **met**, after recovering from the naming-collision incident (Status note 2) — `demo-01`/`demo-02` re-verified `Ready: "True"` with correct baseline resources (no ConfigMap, unlike the advanced examples).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (US1 needs the registry + function image + Helm-migrated baseline + the `dataplanes` Gogs repo registered).
- **User Story 1 (Phase 3)**: Depends on Foundational only. This is the MVP.
- **User Story 2 (Phase 4)**: Depends on Foundational + US1.
- **User Story 3 (Phase 5)**: Depends on Foundational + US1.
- **Polish (Phase 6)**: Depends on whichever of US1/US2/US3 were completed.

### Parallel Opportunities

- T001–T004 (Setup) are all `[P]` — different directories, no dependency.
- T011/T012 (function source + Dockerfile) and T014/T015 (baseline chart template moves) are `[P]` — independent files.
- T025/T026 (`adv-01`/`adv-02` values files) are `[P]` — independent files.
- T034 (US3's `adv-03`) is `[P]` relative to any remaining US2 task — different repo/files entirely.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (Setup) and Phase 2 (Foundational) — registry up, function image
   published once, baseline Composition Helm-migrated and verified non-regressed,
   the `dataplanes` Gogs repo created.
2. Complete Phase 3 (User Story 1) — two example dataplanes provisioned end-to-end
   through the advanced composition.
3. **STOP and VALIDATE** against `quickstart.md` Story 1 before continuing. — done.

### Incremental Delivery

1. Setup + Foundational → registry/function/baseline-chart/repo ready. **Done.**
2. User Story 1 → `adv-01`/`adv-02` provisioned via the advanced composition (MVP). **Done.**
3. User Story 2 → prove the function/chart can be updated and rolled out via Helm
   alone. **Done** (via the real readiness-bug fix, v0.1.0 → v0.1.1).
4. User Story 3 → prove the `dataplanes` repo scales to N instances independently.
   **Done** (`adv-03` added, `adv-02` removed, `adv-01`/`adv-03` unaffected).
5. Polish → docs + full quickstart pass + Success Criteria review. **Done.**
