<!--
Sync Impact Report
- Version change: 1.1.0 → 1.2.0
- Modified principles:
  - II. Hub-and-Spoke Isolation — redefined how a spoke's compute comes to exist
    (vcluster running inside the hub, provisioned via the `XDataPlane` Composition/
    `DataPlane` claim, instead of a manually-created standalone k3d cluster); the
    isolation guarantee itself (no platform tooling on a spoke, resources only via
    `provider-kubernetes`, registration via `ProviderConfig` + out-of-band Secret)
    is unchanged in substance, so this is treated as expanded guidance, not a
    redefinition of the non-negotiable core — hence a MINOR bump, not MAJOR. Also
    now explicitly names ArgoCD Cluster registration as part of "how a spoke is
    registered" (documents an existing mechanism, not a new decision).
- Modified sections: Technology Constraints —
  - First bullet replaced: local clusters are no longer "k3d hub + k3d spoke-01 +
    k3d spoke-02 sharing a Docker network"; only the `hub` remains a real,
    standalone k3d cluster, and every dataplane/spoke is a vcluster
    (loft-sh/vcluster) running as a workload inside it, provisioned exclusively
    through the `XDataPlane` Composition/`DataPlane` claim. `scripts/02-create-
    clusters.sh` creating additional standalone k3d clusters for new spokes is
    retired.
  - Second bullet's worked example corrected: `xdataplanes.lab.example.org` from
    feature 001-dataplane-provisioning is called out explicitly as retired and
    redefined by feature 003-vcluster-dataplanes (same XRD/claim names, different
    meaning — "the spoke cluster itself" instead of "a workload inside an existing
    spoke") — the previous text cited it as a still-valid classic-Composition
    example, which is no longer true; the example was swapped to `s3-bucket`.
  - New bullet added sanctioning `crossplane-contrib/provider-helm`, scoped
    specifically to installing the vcluster project's own Helm chart from within
    the `XDataPlane` Composition — chosen over reimplementing vcluster's manifests
    through `provider-kubernetes` to avoid duplicating logic the upstream chart
    already maintains.
  - `provider-kubernetes` bullet clarified to scope its "only mechanism" claim to
    *reaching an already-provisioned* spoke, distinct from the new
    `provider-helm`-based mechanism for provisioning a spoke's underlying vcluster
    in the first place.
- Added sections: none (amendment lives inside existing Principle II and
  Technology Constraints).
- Removed sections: none.
- Templates requiring follow-up: none — plan/spec/tasks templates already
  reference "Constitution Check" generically.
- Deferred placeholders: none.
- Rationale for MINOR bump: extends/updates guidance (new permitted provisioning
  mechanism for a spoke's compute, one new sanctioned provider, one corrected
  worked example) without removing or redefining the non-negotiable substance of
  any Core Principle (I, III, IV, V untouched; II's isolation guarantee holds,
  only the "how a spoke's compute is created" detail changes).
-->

# argo-crossplane Constitution

## Core Principles

### I. GitOps-Only Changes (NON-NEGOTIABLE)
All platform state — ArgoCD Applications, Crossplane core/providers/ProviderConfigs/
Compositions, and the Gogs deployment itself — MUST be declared as YAML under this
repository and reconciled by ArgoCD. Direct `kubectl apply`/`helm install` against the
`hub` cluster is permitted only for the one-time bootstrap steps documented in
`scripts/` (creating clusters, standing up Gogs before ArgoCD exists, registering
spoke secrets). Every such bootstrap resource MUST have a matching Git-tracked
manifest so ArgoCD adopts and thereafter owns it. Manual, undocumented changes to
live cluster state are prohibited because they silently diverge from Git and defeat
the reason this lab exists.

### II. Hub-and-Spoke Isolation
The `hub` cluster is the only cluster that runs ArgoCD, Gogs, or the Crossplane
control plane. Dataplane/spoke clusters MUST NOT run platform tooling of their own —
they only ever receive resources pushed from the hub via `provider-kubernetes`
`Object` resources. A spoke's compute MUST be provisioned as a vcluster running as a
workload inside the `hub` cluster (see Technology Constraints), created and destroyed
exclusively by submitting or removing a `DataPlane` claim (the `XDataPlane`
Composition) — never by manually creating a standalone cluster — with the sole
exception of the `hub` cluster itself, which remains the one real,
imperatively-created k3d cluster. A spoke is registered by creating a
`ProviderConfig` in `crossplane/config/` whose name matches the spoke, backed by a
kubeconfig `Secret` created out-of-band (never committed), and by registering it as a
Cluster in ArgoCD (credentials likewise sourced out-of-band, never committed) so
ArgoCD Applications can address it by name. Compositions MUST select the target
spoke only through `spec.parameters.spoke` → `providerConfigRef.name`; they MUST NOT
hardcode cluster endpoints or credentials inline.

### III. App-of-Apps Structure
Every platform component is a distinct child `Application` under `gitops/apps/`,
each pointing at exactly one path in this repo, with an explicit
`argocd.argoproj.io/sync-wave` annotation reflecting real dependency order (core
before providers, providers before ProviderConfigs/Compositions). The only
Application ever applied by hand is the root `gitops/root/app-of-apps.yaml`; every
other Application MUST be reachable by ArgoCD discovering it under `gitops/apps/`.
Child Applications MUST set `syncPolicy.automated.{prune,selfHeal}: true` and
`CreateNamespace=true` so the tree self-heals without operator intervention.

### IV. Composable, Testable Compositions
Every `CompositeResourceDefinition` added under `crossplane/compositions/` MUST ship
with at least one `Composition` and at least one example claim under
`crossplane/examples/` (or, for a Composition whose instances are declared via a
dedicated instances repository per the Technology Constraints below, at least one
real instance declared there) that has been applied against a real spoke and
verified end-to-end (resources observed running in the target spoke namespace)
before the feature is considered done. A Composition merged without a working
example is incomplete work, not a stopping point.

### V. Secrets Never Committed
Kubeconfigs, admin passwords, and tokens (spoke kubeconfigs, Gogs admin credentials,
ArgoCD repository credentials, private registry credentials) MUST be generated and
stored out-of-band — under `.secrets/` (git-ignored) or as Kubernetes `Secret`
objects created by scripts — and referenced from Git-tracked manifests only by name
(`secretRef`). No YAML committed to this repository may contain a real credential,
private key, or kubeconfig.

## Technology Constraints

- The `hub` cluster is provisioned with k3d and is the only real, standalone
  Kubernetes cluster this lab depends on. Every dataplane/spoke MUST instead be a
  vcluster (the loft-sh/vcluster project) running as a workload inside the `hub`
  cluster, provisioned exclusively through the `XDataPlane` Composition (claim
  `DataPlane`) — never as a separate k3d cluster. `scripts/02-create-clusters.sh`
  creating additional standalone k3d clusters for new spokes is retired; any new
  dataplane/spoke MUST come from a `DataPlane` claim, not a new k3d cluster.
- Crossplane's classic v1.x cluster-scoped Composition (Patch-and-Transform via
  `spec.resources`) remains valid and MUST keep working for every Composition that
  predates this amendment and is still in use (e.g. `s3-bucket` from feature
  002-golang-composition-pipeline). Crossplane Composition Functions (v1.x
  function-pipeline mode, `spec.mode: Pipeline`) are additionally permitted for new,
  more advanced example Compositions (e.g. feature 002-golang-composition-pipeline),
  provided they still select the target spoke exclusively through
  `providerConfigRef.name` per Principle II. Adopting Crossplane v2 (namespaced XRs)
  remains a deliberate, separate future amendment, not authorized by this change.
  Note: the XRD/claim pair `XDataPlane`/`DataPlane` originally introduced by feature
  001-dataplane-provisioning (meaning "a workload inside an already-existing spoke")
  is retired and its name reused, with a different meaning ("the spoke cluster
  itself"), by feature 003-vcluster-dataplanes — it is not an example of a
  still-valid, unchanged pre-existing Composition.
- Any Composition Function's container image MUST be published to, and pulled from,
  a private OCI registry that itself runs in the hub and is provisioned through this
  repository's GitOps automation (Principle I) — a Composition Function MUST NOT
  depend on a public/external registry for normal cluster operation. Base or builder
  images used only at build time (never pulled by the running cluster) are exempt.
- Any Composition — classic or function-pipeline — that ArgoCD installs or upgrades
  MUST be packaged and released as a Helm chart. A plain directory of manifests
  (`directory.recurse`) is not a valid delivery mechanism for a Composition once this
  amendment is in effect; a Composition Application predating this amendment MUST be
  migrated to a Helm-based Application before or as part of the change that touches
  it next.
- `provider-kubernetes` is the only mechanism used to reach an already-provisioned
  spoke from the hub (applying workload resources into it). Provisioning a spoke's
  underlying vcluster in the first place is the one sanctioned exception: the
  `XDataPlane` Composition MUST use `crossplane-contrib/provider-helm` to install the
  vcluster project's own Helm chart, rather than reimplementing its manifests through
  `provider-kubernetes`. Introducing any other multi-cluster or cluster-provisioning
  mechanism (e.g. Cluster API, a commercial Crossplane multi-cluster feature)
  requires amending this constitution first.
- Gogs (not GitHub or another SaaS) is the git source ArgoCD reconciles from inside
  the cluster, so the lab keeps working without external network access once
  bootstrapped. A GitHub remote (`origin`) MAY additionally exist for human
  collaboration/backup, but it is never what ArgoCD points at. A Composition's
  source code (when non-trivial, e.g. a Composition Function written in Go) and a
  set of declared instances of a Composition (e.g. per-dataplane values) MAY each
  live in their own dedicated Gogs repository, separate from the platform GitOps
  repository, provided ArgoCD still reconciles from Gogs per Principle I.

## Development Workflow

- Changes are made locally, committed, and pushed to whichever remotes are
  configured for this repo (e.g. `origin` for GitHub, `gogs` for the in-cluster
  source). Before relying on ArgoCD to reflect a change, the `gogs` remote MUST be
  up to date — GitHub alone is not sufficient, since ArgoCD never talks to it.
- New spokes, new Compositions, or changes to sync-wave ordering MUST go through
  `/speckit-specify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-implement` so
  the change is documented before it is built, matching how this repo is meant to
  evolve.
- Scripts under `scripts/` are the only sanctioned bootstrap path; a change that
  requires a new one-time manual step MUST add or update a numbered script rather
  than leaving the step as tribal knowledge in a chat log or README prose alone.

## Governance

This constitution supersedes ad-hoc practice for this repository. Amendments are
made by re-running `/speckit-constitution` with the proposed change, which MUST
update the version per semantic versioning (MAJOR for incompatible principle
removal/redefinition, MINOR for a new principle or materially expanded guidance,
PATCH for clarification/wording) and refresh `Last Amended`. `/speckit-analyze`
SHOULD be run before `/speckit-implement` on any feature to confirm the plan and
tasks stay compliant with the principles above; deviations must be justified in the
feature's plan, not silently merged.

**Version**: 1.2.0 | **Ratified**: 2026-09-18 | **Last Amended**: 2026-09-24
