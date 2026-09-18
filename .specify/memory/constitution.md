<!--
Sync Impact Report
- Version change: (none) → 1.0.0 (initial ratification)
- Modified principles: n/a (first version)
- Added sections: Core Principles (5), Technology Constraints, Development Workflow, Governance
- Removed sections: none
- Templates requiring follow-up: none — plan/spec/tasks templates already reference
  "Constitution Check" generically and need no structural change for this ratification.
- Deferred placeholders: none. Values below were inferred from the existing repo
  (README.md, gitops/, crossplane/, scripts/) since no explicit principles were
  supplied in the conversation; review and amend if any inference misrepresents intent.
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
`crossplane/examples/` that has been applied against a real spoke and verified
end-to-end (resources observed running in the target spoke namespace) before the
feature is considered done. A Composition merged without a working example is
incomplete work, not a stopping point.

### V. Secrets Never Committed
Kubeconfigs, admin passwords, and tokens (spoke kubeconfigs, Gogs admin credentials,
ArgoCD repository credentials) MUST be generated and stored out-of-band — under
`.secrets/` (git-ignored) or as Kubernetes `Secret` objects created by scripts — and
referenced from Git-tracked manifests only by name (`secretRef`). No YAML committed
to this repository may contain a real credential, private key, or kubeconfig.

## Technology Constraints

- Local clusters are provisioned with k3d; `hub`, `spoke-01`, and `spoke-02` (and any
  future spoke) MUST share one Docker network (`hublab`) so the hub can reach spoke
  API servers by container DNS name, and each spoke MUST be created with a
  `--tls-san` matching its own server container name.
- Crossplane is pinned to the latest v1.x line (classic cluster-scoped Composition /
  Patch-and-Transform via `spec.resources`), not v2's namespaced-XR / function-pipeline
  model, so the hub-and-spoke pattern stays simple to read. Moving to v2 or to
  Composition Functions is a deliberate, separate amendment, not an incidental
  upgrade.
- `provider-kubernetes` is the only mechanism used to reach spokes from the hub.
  Introducing a different multi-cluster mechanism (e.g. Cluster API, a commercial
  Crossplane multi-cluster feature) requires amending this constitution first.
- Gogs (not GitHub or another SaaS) is the git source ArgoCD reconciles from inside
  the cluster, so the lab keeps working without external network access once
  bootstrapped. A GitHub remote (`origin`) MAY additionally exist for human
  collaboration/backup, but it is never what ArgoCD points at.

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

**Version**: 1.0.0 | **Ratified**: 2026-09-18 | **Last Amended**: 2026-09-18
