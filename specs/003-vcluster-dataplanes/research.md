# Phase 0 Research: vcluster-Based Dataplane Clusters

## 1. Which vcluster distribution/chart, and how is it installed?

**Decision**: `crossplane-contrib/provider-helm`'s `Release` resource, installing the
official `loft-sh/vcluster` Helm chart from its public upstream chart repository
(`https://charts.loft.sh`), one release per `DataPlane` claim, in a namespace named
after the claim (e.g. release `spoke-01` in namespace `spoke-01`).

**Rationale**: This is the vcluster project's own documented, supported install
method, and the operator explicitly chose `provider-helm` over reimplementing the
chart's manifests via `provider-kubernetes` (see feature 003's constitution
amendment, v1.2.0) — reimplementing would mean permanently tracking vcluster's own
internal manifest changes by hand.

**Alternatives considered**:
- A dedicated Crossplane vcluster provider — none exists as a maintained,
  widely-used package at the time of writing; not worth depending on an
  unmaintained/community package for a core lab mechanism.
- `provider-kubernetes` applying the chart's rendered output as static manifests —
  rejected per the operator's explicit choice; also brittle across vcluster chart
  upgrades.

## 2. How does an existing spoke-addressing mechanism reach a vcluster, given it used to reach a real k3d cluster over a shared Docker network?

**Decision**: Configure the vcluster chart's values so the kubeconfig it
auto-generates uses the in-cluster Service DNS name
(`https://<release>.<namespace>.svc.cluster.local:443`, the standard vcluster chart
`exportKubeConfig` override) as the `server`, instead of its `localhost`-oriented
default (meant for `vcluster connect`/local port-forward workflows). Both consumers
of a spoke's kubeconfig — `provider-kubernetes`'s `ProviderConfig` and the
ArgoCD-cluster-registration script — already run *inside* the hub cluster, so
standard Kubernetes Service DNS resolves natively. This is simpler than the
Docker-network-container-IP workaround `scripts/03-register-spokes.sh` needed for
real k3d spokes (no `--tls-san`/`insecure-skip-tls-verify` hack required — see #3).

**Rationale**: The whole reason the old mechanism needed a manual kubeconfig
rewrite (container IP substitution, dropped CA, `insecure-skip-tls-verify`) was that
`provider-kubernetes` and the operator's own `kubectl` sat *outside* the spoke's own
Docker network naming, and the spoke's own TLS cert didn't cover that identity.
Inside one Kubernetes cluster, standard in-cluster DNS plus a cert vcluster already
issues for its own Service removes both problems.

**Alternatives considered**: NodePort or a dedicated Ingress per vcluster — rejected
as unnecessary; nothing outside the hub cluster ever needs to reach a spoke's API
server directly (the only outside-facing per-spoke access this lab has ever needed
is `kubectl --context k3d-spoke-0N` for manual verification during development,
which becomes `kubectl --context <vcluster-local-context>` obtained via the
`vcluster` CLI or a temporary port-forward when needed — not a standing requirement
the platform itself must serve).

## 3. TLS: can `insecure-skip-tls-verify` be dropped?

**Decision**: Attempt to consume the vcluster-generated kubeconfig's own
`certificate-authority-data` as-is (vcluster issues its API server's serving
certificate for its own Service's DNS name by default in recent chart versions).
Fall back to `insecure-skip-tls-verify: true` (matching the existing k3d-spoke
precedent) only if the shipped CA does not validate against the Service DNS name
actually used — to be confirmed empirically during implementation, same as several
other integration details in this project's history (e.g. the registry's TLS
handling, ADR-006/007-equivalent discoveries in feature 002).

**Rationale**: Prefer real TLS verification when it's free; this lab has never
treated `insecure-skip-tls-verify` as a goal, only as a pragmatic workaround for a
specific constraint (SANs not covering a Docker container IP) that no longer applies
once the "spoke" is a Service inside the same cluster.

**Alternatives considered**: None — this is a low-risk, empirically-resolved detail,
not a design fork.

## 4. Where does the vcluster's kubeconfig Secret actually land, and what shape is it?

**Decision**: Read it directly from wherever the vcluster chart creates it (by
convention, a Secret in the vcluster's own namespace, commonly named `vc-<release
name>`), rather than copying it into a fixed `crossplane-system/<spoke>-kubeconfig`
Secret the way `scripts/03-register-spokes.sh` used to create by hand. Both
`ProviderConfig.spec.credentials.secretRef` and the ArgoCD-registration script
support referencing a Secret in any namespace by name — a copy step is unnecessary
complexity now that everything lives in one cluster.

**Rationale**: Removing a manual copy step removes a class of drift (a stale copy
surviving after the source rotates) and is strictly simpler than what it replaces.

**Alternatives considered**: Have the `XDataPlane` Composition itself copy the
Secret into a fixed-name/fixed-namespace convention (e.g. via a second composed
`provider-kubernetes` `Object`) — considered, but adds a moving part with no benefit
once direct reference is confirmed to work; deferred unless direct reference proves
impractical during implementation.

## 5. RBAC: what does `provider-helm`'s `InjectedIdentity` credential need?

**Decision**: An aggregated `ClusterRole` (label
`rbac.crossplane.io/aggregate-to-crossplane: "true"`, the same mechanism
`provider-kubernetes`'s existing RBAC already uses in this repo) granting the
permissions the vcluster chart's rendered resources require (at minimum:
`apps` Deployments/StatefulSets, `core` Services/Secrets/ConfigMaps/
ServiceAccounts/PersistentVolumeClaims, `rbac.authorization.k8s.io` Roles/
RoleBindings, `networking.k8s.io` if the chart creates any). Exact resource list to
be finalized empirically against the actual chart version pinned in
`compositions/dataplane-cluster/chart/values.yaml` — broad enough to avoid repeated
trial-and-error, scoped to what a namespaced Helm release plausibly needs (not
cluster-admin).

**Rationale**: Matches this repo's existing pattern exactly (see
`crossplane/providers/provider-kubernetes.yaml`'s `provider-kubernetes-secrets`
aggregated `ClusterRole`) — no new RBAC delivery mechanism needed, just a new
aggregated role with a wider rule set appropriate to what `provider-helm` does.

**Alternatives considered**: Binding `cluster-admin` directly — rejected as broader
than necessary and inconsistent with this project's existing least-privilege
aggregated-ClusterRole pattern.

## 6. What does the `XDataPlane` Composition's claim schema need?

**Decision**: No required parameters beyond the claim's own `metadata.name` (used
directly as both the vcluster release name and its namespace). `spec.parameters`
stays present (matching this project's XRD convention) but with only optional
fields — e.g. an optional `kubernetesVersion` passed through to the vcluster chart,
defaulting to whatever the chart itself defaults to if omitted.

**Rationale**: Matches spec User Story 1 exactly ("operator creates a `DataPlane`
claim naming the new dataplane") — no other input is described as required, and
adding required fields not asked for would violate this project's no-speculative-
scope norm.

**Alternatives considered**: Requiring explicit CPU/memory sizing per claim —
rejected for v1; the chart's own defaults are adequate for a lab, and this can be
added later without a breaking schema change (it would only ever be additive/
optional).

## 7. How does a `DataPlane` claim actually get created from Git (User Story 1)?

**Decision**: Extend the existing `charts/dataplane-cluster` wrapper chart (in the
platform repo, already rendered once per `dataplanes/<spoke>.yaml` file by the
`dataplanes` `ApplicationSet`) with one more always-present template that renders
exactly one `DataPlane` claim named `{{ .Values.cluster }}`, regardless of whether
that file's `charts:`/`compositions:` lists are empty. Adding a new
`dataplanes/<spoke>.yaml` file (even an otherwise-empty one) is therefore already
sufficient to bring a new vcluster into existence — satisfying User Story 1 without
inventing a second, parallel Git-driven mechanism.

**Rationale**: Reuses the exact multi-source Application/`files`-generator machinery
already built and verified (ADR-029) for "what runs on a spoke," extending it to
also answer "does this spoke exist" from the same file — one source of truth per
spoke, not two.

**Alternatives considered**: A separate `ApplicationSet`/generator dedicated only to
claim creation — rejected; would require operators to reason about two different
Git-driven mechanisms for what is conceptually one spoke's lifecycle.

## 8. Registration ordering: the claim/vcluster vs. the registration scripts

**Decision**: Registration (the `ProviderConfig` and the ArgoCD Cluster Secret)
remains an out-of-band script step run after a new spoke's vcluster is `Ready`,
exactly matching how registration already works today for a new spoke declared in
`dataplanes/<spoke>.yaml` (per this project's own `dataplanes` repo README: run once
"the first time it appears"). This feature does not attempt to fully automate
registration inside the Composition itself — that would go beyond what the spec
asked for (FR-004 explicitly preserves "the existing
`scripts/16-register-argocd-clusters.sh`/`dataplanes/<spoke>.yaml` mechanism").

**Rationale**: Keeps the Composition single-purpose (create the vcluster) and keeps
this feature's blast radius matched to its spec, rather than silently expanding
scope to "fully automatic zero-script registration," which was not requested.

**Alternatives considered**: Have the Composition also compose the `ProviderConfig`
directly (Crossplane can compose arbitrary resource types, including another
provider's `ProviderConfig`) — a legitimate future enhancement, explicitly deferred
as out of scope for this feature per the spec's own FR-004 wording.
