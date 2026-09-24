# Feature Specification: vcluster-Based Dataplane Clusters (XDataPlane Redefined)

**Feature Branch**: `003-vcluster-dataplanes`

**Created**: 2026-09-23

**Status**: Draft

**Input**: User description: "quero trocar os clusters 'dataplanes' do k3d por vclusters, iniciados dentro do k3d principal" (replace the k3d 'dataplane' spoke clusters with vclusters started inside the main/hub k3d cluster), followed by "deve ser uma composition chamada XDataplane" (this must be exposed as a Composition called XDataplane), followed by a clarification that the existing `XDataPlane`/`DataPlane` Composition from feature 001-dataplane-provisioning (which today creates a Namespace+Deployment+Service *inside* an already-existing spoke) MUST be removed and its name reused for this new Composition, which instead provisions the dataplane/spoke *cluster itself*.

## User Scenarios & Testing *(mandatory)*

Terminology used throughout (per this project's established convention):
spoke = cluster = dataplane (the same thing, three names for different
contexts); control-plane = hub.

### User Story 1 - Provision a new dataplane cluster by submitting a claim (Priority: P1)

A platform operator wants a new dataplane/spoke cluster to exist. Instead of running
k3d/Docker commands to create a new standalone cluster and wire it into the shared
Docker network, the operator submits a `DataPlane` claim (the redefined `XDataPlane`
Composition) naming the new dataplane. Crossplane provisions a vcluster — a virtual
Kubernetes cluster running as a workload inside the hub k3d cluster — and
automatically registers it exactly as a real spoke is registered today, so every
other part of the platform (Crossplane `provider-kubernetes`, the ArgoCD Cluster
registration, the `dataplanes` repository's charts/compositions-per-cluster model)
can address it purely by name.

**Why this priority**: This is the entire point of the feature — turning
dataplane-cluster creation from an imperative, Docker-network-dependent bootstrap
step into a declarative, Crossplane-managed, GitOps lifecycle. Nothing else in this
feature matters if this does not work.

**Independent Test**: Submit a `DataPlane` claim for a new name (e.g. `spoke-03`) and
confirm, without running any k3d or Docker command by hand: a vcluster is running
inside the hub, a kubeconfig `Secret` and matching `provider-kubernetes`
`ProviderConfig` exist for it, it is registered as a Cluster in ArgoCD, and a trivial
resource applied through `provider-kubernetes` against that `ProviderConfig` lands
inside the vcluster.

**Acceptance Scenarios**:

1. **Given** no dataplane named `spoke-03` exists, **When** a platform operator
   commits a `DataPlane` claim named `spoke-03`, **Then** a vcluster for `spoke-03`
   becomes `Ready`, running entirely inside the hub cluster.
2. **Given** the `spoke-03` vcluster is `Ready`, **When** the platform's existing
   spoke-registration mechanisms run, **Then** a `ProviderConfig` named `spoke-03`
   and an ArgoCD Cluster named `spoke-03` both exist and are usable, with no manual
   kubeconfig handling by the operator.

---

### User Story 2 - Everything that already targets a spoke keeps working unmodified (Priority: P2)

A platform operator who already has dataplane workloads declared against `spoke-01`
and `spoke-02` (via the `dataplane-advanced` Composition and the `dataplanes`
repository's per-cluster `charts:`/`compositions:` entries) sees no difference after
those spokes become vcluster-backed. Everything that previously selected a spoke by
name continues to work by name, with no edits required to any existing claim, chart,
or `dataplanes/<spoke>.yaml` file.

**Why this priority**: This protects everything built by the two previous features on
top of the spoke concept. Without this, replacing the underlying cluster technology
would be a regression, not a migration.

**Independent Test**: With `spoke-01` migrated to a vcluster, confirm an existing
`AdvancedDataPlane` claim targeting `spoke-01` (and an existing entry in
`dataplanes/spoke-01.yaml`) still results in the same running resources inside
`spoke-01`, with zero changes to the claim, the chart, or the values file.

**Acceptance Scenarios**:

1. **Given** an `AdvancedDataPlane` claim already targeting `spoke-01` before
   migration, **When** `spoke-01` is migrated from a real k3d cluster to a vcluster,
   **Then** the claim remains `Ready` and its composed resources are running inside
   the new vcluster, without editing the claim.
2. **Given** `dataplanes/spoke-01.yaml` already lists a chart applied directly on
   `spoke-01`, **When** `spoke-01` becomes vcluster-backed, **Then** that chart's
   `Application` remains `Synced`/`Healthy` against the same cluster name, with no
   edit to `dataplanes/spoke-01.yaml`.

---

### User Story 3 - Remove a dataplane cluster by deleting its claim (Priority: P3)

A platform operator no longer needs a dataplane. Deleting its `DataPlane` claim tears
down the vcluster and everything that was running inside it, and cleanly removes its
`ProviderConfig` and ArgoCD Cluster registration — leaving no orphaned resources
behind in the hub.

**Why this priority**: Lifecycle completeness. The lab is already useful once User
Story 1 works; without teardown, the hub accumulates orphaned vclusters and stale
registrations over time, which is a real operational cost but not a blocker for the
core value.

**Independent Test**: With a vcluster-backed dataplane provisioned and confirmed
running, delete its `DataPlane` claim and confirm the vcluster, its
`ProviderConfig`, and its ArgoCD Cluster Secret are all gone.

**Acceptance Scenarios**:

1. **Given** a `DataPlane` claim for `spoke-03` is `Ready`, **When** the claim is
   deleted, **Then** the `spoke-03` vcluster's resources are removed from the hub.
2. **Given** the `spoke-03` vcluster has been removed, **When** the platform's
   spoke-registration state is inspected, **Then** neither a `ProviderConfig` nor an
   ArgoCD Cluster named `spoke-03` remain.

---

### Edge Cases

- What happens to the existing feature-001 baseline example claims/resources
  (`dp-demo-01`, `dp-demo-02` and the `DataPlane` claims that created them)? They
  MUST be removed as part of this change, since the `DataPlane` claim kind is being
  redefined to mean something different (a dataplane cluster itself, not a workload
  inside one) — they cannot continue to exist under the old meaning.
- What happens when something targets a vcluster-backed spoke before its vcluster has
  finished starting and is not yet reachable? The system MUST surface a clear
  failure/pending status and converge once the vcluster becomes reachable, rather
  than silently misrouting or failing permanently (same contract as existing
  spoke-targeting failures).
- What happens when two `DataPlane` claims are submitted with the same name? The
  system MUST reject or otherwise prevent a naming collision — this project has
  already hit a real incident from two differently-scoped resources landing on the
  same generated name (see `docs/decisions.md`, ADR-019), so this MUST NOT recur for
  dataplane-cluster names.
- What happens to workloads already declared against a spoke (an `AdvancedDataPlane`
  claim, or `dataplanes/<spoke>.yaml` entries) when that spoke's `DataPlane` claim is
  deleted while they still reference it? The system MUST surface a clear
  failure/orphaned status for those dependents rather than silently succeeding or
  leaving them pointed at nothing.
- What happens under hub node resource contention now that dataplane clusters are
  pods scheduled on the same node as ArgoCD, Gogs, the Crossplane control plane, and
  MiniStack, instead of separate k3d containers? This is a new class of failure mode
  introduced by this feature (previously, spokes were isolated Docker containers) and
  MUST be documented as a known constraint even if not fully solved by this feature.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST remove the existing baseline Composition (XRD `XDataPlane`,
  claim kind `DataPlane`, from feature 001-dataplane-provisioning) that provisions a
  Namespace+Deployment+Service *inside* an already-existing spoke, including its
  existing example claims and the resources they created.
- **FR-002**: System MUST provide a new Composition that reuses the same names (XRD
  `XDataPlane`, claim kind `DataPlane`), whose purpose is instead to provision an
  entire dataplane/spoke *cluster*, implemented as a vcluster (a virtual Kubernetes
  cluster) running as a workload inside the hub k3d cluster.
- **FR-003**: Submitting a `DataPlane` claim MUST result in a running, addressable
  vcluster with no manual step beyond committing/applying the claim through Git
  (Constitution Principle I — GitOps-Only Changes).
- **FR-004**: Each provisioned vcluster MUST be automatically registered exactly as a
  real spoke is registered today: a `provider-kubernetes` `ProviderConfig` backed by
  a kubeconfig `Secret` generated and stored out-of-band (Constitution Principle
  II/V), and a Cluster registration in ArgoCD (the existing
  `scripts/16-register-argocd-clusters.sh` / `dataplanes/<spoke>.yaml` mechanism).
- **FR-005**: Existing spoke-dependent Compositions (`dataplane-advanced`) and the
  `dataplanes` repository's per-cluster `charts:`/`compositions:` model MUST continue
  to work unmodified against a vcluster-backed spoke, addressing it purely by name
  (`spec.parameters.spoke`, `providerConfigRef.name`, `destination.name`) — no
  changes to those Compositions or to any existing `dataplanes/<spoke>.yaml` file.
- **FR-006**: Deleting a `DataPlane` claim MUST tear down its vcluster and deregister
  it (its `ProviderConfig` and its ArgoCD Cluster Secret), leaving no orphaned
  resources in the hub.
- **FR-007**: The two dataplane clusters currently provisioned as real, standalone k3d
  clusters (`spoke-01`, `spoke-02`) MUST be migrated to vcluster-backed `DataPlane`
  claims as part of delivering this feature, not left as a follow-up.
- **FR-008**: A vcluster-backed spoke MUST NOT run any platform tooling of its own
  (ArgoCD, Gogs, the Crossplane control plane) — Constitution Principle II's
  isolation guarantee continues to hold for vcluster-backed spokes exactly as it did
  for real k3d spokes.
- **FR-009**: The bootstrap scripts that create and register spokes via k3d/Docker
  (`scripts/02-create-clusters.sh`, `scripts/03-register-spokes.sh`) MUST be updated
  to reflect that dataplane-cluster lifecycle is now Crossplane/GitOps-managed; only
  the hub cluster itself remains a real, imperatively-created k3d cluster after this
  feature.

### Key Entities

- **DataPlane (claim)**: redefined by this feature. Previously: a request for a
  workload (Namespace+Deployment+Service) inside an already-existing spoke.
  Going forward: a single named request for an entire dataplane/spoke *cluster*,
  resulting in one running vcluster.
- **XDataPlane (Composite Resource Definition)**: the Crossplane API exposing
  dataplane-cluster provisioning; same name as feature 001's XRD, redefined
  implementation and meaning.
- **vcluster**: the virtual Kubernetes cluster instance that backs one `DataPlane`
  claim, running as a workload inside the hub cluster.
- **AdvancedDataPlane (claim, unchanged by this feature)**: still means "a workload
  inside a named spoke" — now potentially a vcluster-backed spoke rather than a real
  k3d cluster.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A platform operator brings a new dataplane cluster online by committing
  exactly one claim to Git — zero k3d or Docker commands — and it is fully
  addressable (workloads deployable via `provider-kubernetes`, visible as an ArgoCD
  Cluster) within 5 minutes of the claim being applied.
- **SC-002**: 100% of the existing dataplane-advanced-workload and `dataplanes`
  repository verification steps continue to pass, unmodified, once `spoke-01` and
  `spoke-02` are vcluster-backed.
- **SC-003**: Deleting a `DataPlane` claim results in its vcluster and both
  registrations (`ProviderConfig`, ArgoCD Cluster) being fully removed within 5
  minutes, with zero orphaned resources left in the hub.
- **SC-004**: The number of real, standalone k3d clusters the lab depends on drops
  from 3 (hub, spoke-01, spoke-02) to 1 (hub only), while the number of usable
  dataplane clusters stays the same or grows without creating any new k3d cluster.

## Assumptions

- "vcluster" refers to the loft-sh/vcluster open-source project — the only
  widely-known tool matching that name in the Kubernetes ecosystem. No other
  interpretation was considered.
- Reusing the name `XDataPlane`/`DataPlane` means feature 001's original baseline
  Composition and its concept are retired, not kept alongside under a different
  name — confirmed explicitly by the operator during specification.
- The two existing spoke names (`spoke-01`, `spoke-02`) are preserved as the
  `DataPlane` claim names after migration, to avoid unnecessary churn in the
  `dataplanes` repository and every existing reference to them.
- No live data/state migration is required from the feature-001 baseline example
  resources being removed (`dp-demo-01`, `dp-demo-02`) — they are disposable demo
  workloads (`nginxdemos/hello`), not resources with data worth preserving.
- What runs *inside* a dataplane cluster (workload placement, via
  `dataplane-advanced` and the `dataplanes` repository's charts/compositions
  catalog) is unchanged in shape by this feature — only the underlying cluster
  technology of the spoke itself changes, from a real k3d cluster to a vcluster.
- The vcluster control-plane/syncer images are pulled from their public upstream
  registry, consistent with how other third-party platform images already used in
  this lab (ArgoCD, Gogs, MiniStack, StackPort, `registry:2`) are sourced — the
  Constitution's private-registry requirement is scoped specifically to Composition
  Function images, not to every third-party image the platform depends on.
