<!--
Sync Impact Report
- Version change: 1.0.0 → 1.1.0
- Modified principles: none redefined/removed (I-V unchanged)
- Modified sections: Technology Constraints — Crossplane bullet expanded to
  additionally permit Composition Functions (function-pipeline mode) for new,
  advanced example Compositions, alongside the existing classic v1.x
  Patch-and-Transform model (both now coexist; v2/namespaced-XR migration is
  still a separate future amendment). Two new bullets added: private-registry
  requirement for Composition Function images, and mandatory Helm packaging for
  any Composition ArgoCD installs/upgrades.
- Added sections: none (amendment lives inside existing Technology Constraints)
- Removed sections: none
- Templates requiring follow-up: none — plan/spec/tasks templates already
  reference "Constitution Check" generically.
- Deferred placeholders: none.
- Rationale for MINOR bump: materially expands Technology Constraints guidance
  (new permitted pattern + two new mandatory constraints) without removing or
  redefining any existing non-negotiable principle (I-V untouched).
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
control plane. Spoke clusters (`spoke-01`, `spoke-02`, and any added later) MUST NOT
run platform tooling of their own — they only ever receive resources pushed from the
hub via `provider-kubernetes` `Object` resources. A spoke is registered by creating a
`ProviderConfig` in `crossplane/config/` whose name matches the spoke, backed by a
kubeconfig `Secret` created out-of-band (never committed). Compositions MUST select
the target spoke only through `spec.parameters.spoke` → `providerConfigRef.name`;
they MUST NOT hardcode cluster endpoints or credentials inline.

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

- Local clusters are provisioned with k3d; `hub`, `spoke-01`, and `spoke-02` (and any
  future spoke) MUST share one Docker network (`hublab`) so the hub can reach spoke
  API servers by container DNS name, and each spoke MUST be created with a
  `--tls-san` matching its own server container name.
- Crossplane's classic v1.x cluster-scoped Composition (Patch-and-Transform via
  `spec.resources`) remains valid and MUST keep working for every Composition that
  predates this amendment (e.g. `xdataplanes.lab.example.org` from feature
  001-dataplane-provisioning). Crossplane Composition Functions (v1.x
  function-pipeline mode, `spec.mode: Pipeline`) are additionally permitted for new,
  more advanced example Compositions (e.g. feature 002-golang-composition-pipeline),
  provided they still select the target spoke exclusively through
  `providerConfigRef.name` per Principle II. Adopting Crossplane v2 (namespaced XRs)
  remains a deliberate, separate future amendment, not authorized by this change.
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
- `provider-kubernetes` is the only mechanism used to reach spokes from the hub.
  Introducing a different multi-cluster mechanism (e.g. Cluster API, a commercial
  Crossplane multi-cluster feature) requires amending this constitution first.
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

**Version**: 1.1.0 | **Ratified**: 2026-09-18 | **Last Amended**: 2026-09-19
