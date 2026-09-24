# Phase 0 Research: vcluster-Based Dataplane Clusters

## 1. Which vcluster distribution/chart, and how is it installed?

**Decision**: `crossplane-contrib/provider-helm`'s `Release` resource, installing the
official `loft-sh/vcluster` Helm chart from its public upstream chart repository
(`https://charts.loft.sh`, chart `vcluster`, confirmed reachable and pinned to
`0.37.2`, its current stable release), one release per `DataPlane` claim, in a
namespace named after the claim (e.g. release `spoke-01` in namespace `spoke-01`).
Provider package: `xpkg.crossplane.io/crossplane-contrib/provider-helm:v1.4.0` (the
registry host `provider-helm`'s own official examples use, distinct from
`xpkg.upbound.io` used by this repo's other providers — both are public OCI
registries; followed the upstream-documented one rather than assuming parity).

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
auto-generates uses the in-cluster Service DNS name as the `server` — but the
**short** two-label form, `https://<release>.<namespace>:443`, not the full FQDN
(`...svc.cluster.local`). Confirmed by direct testing (a debug pod mounting the
generated kubeconfig Secret): the vcluster's own TLS certificate's SANs include
`kubernetes.default.svc.cluster.local`, the release name alone, and
`<release>.<namespace>`, but **not** `<release>.<namespace>.svc.cluster.local` — so
the full FQDN fails certificate verification
(`x509: certificate is valid for ... not <fqdn>`) while the short form succeeds with
real TLS (no `insecure-skip-tls-verify` needed at all, see #3). The short form
resolves correctly via the pod's default DNS search list (confirmed via `getent
hosts`). Both consumers of a spoke's kubeconfig — `provider-kubernetes`'s
`ProviderConfig` and the ArgoCD-cluster-registration script — already run *inside*
the hub cluster, so this resolves natively. Simpler than the
Docker-network-container-IP workaround `scripts/03-register-spokes.sh` needed for
real k3d spokes either way.

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

**Decision**: Yes, confirmed by direct testing — dropped entirely. The
vcluster-generated kubeconfig's own `certificate-authority-data`, combined with
using the short `<release>.<namespace>` server form (see #2), verifies
successfully; `kubectl get ns` against the freshly-created `dataplane-cluster-test`
vcluster succeeded with zero TLS flags. `exportKubeConfig.insecure` stays `false`
(the chart's own default).

**Rationale**: Prefer real TLS verification when it's free; this lab has never
treated `insecure-skip-tls-verify` as a goal, only as a pragmatic workaround for a
specific constraint (SANs not covering a Docker container IP) that doesn't apply
once the "spoke" is a Service inside the same cluster.

**Alternatives considered**: None needed — resolved cleanly on the first real test.

## 4. Where does the vcluster's kubeconfig Secret actually land, and what shape is it?

**Decision**: Read it directly from wherever the vcluster chart creates it —
confirmed by both the chart's own `values.yaml` comment and direct testing: a Secret
named `vc-<release name>` in the vcluster's own namespace (its creation is logged by
the running syncer: `"Applied kube config secret <namespace>/vc-<name>"`). Better
than expected: it has **separate, already-decoded-shape keys**, not just one
`config` blob needing YAML parsing — `certificate-authority`, `client-certificate`,
`client-key`, `token`, and `config` (the full kubeconfig, for convenience/tools that
want it). `ProviderConfig`/the registration script can read `certificate-authority`,
`client-certificate`, and `client-key` directly, no kubeconfig-YAML parsing
required — simpler than the `kubectl config view --kubeconfig=...` extraction
`scripts/16-register-argocd-clusters.sh` previously needed for a real k3d spoke's
kubeconfig file. Read directly rather than copied into a fixed
`crossplane-system/<spoke>-kubeconfig` Secret the way
`scripts/03-register-spokes.sh` used to create by hand — both
`ProviderConfig.spec.credentials.secretRef` and the ArgoCD-registration script
support referencing a Secret in any namespace by name, so a copy step is unnecessary
complexity now that everything lives in one cluster.

**Rationale**: Removing a manual copy step removes a class of drift (a stale copy
surviving after the source rotates) and is strictly simpler than what it replaces.

**Alternatives considered**: Have the `XDataPlane` Composition itself copy the
Secret into a fixed-name/fixed-namespace convention (e.g. via a second composed
`provider-kubernetes` `Object`) — considered, but adds a moving part with no benefit
once direct reference is confirmed to work; deferred unless direct reference proves
impractical during implementation.

## 5. RBAC: what does `provider-helm`'s `InjectedIdentity` credential need?

**Decision** (revised twice — first from reasoning, then corrected again by a live
test failure): follow `provider-helm`'s own official in-cluster example exactly —
`DeploymentRuntimeConfig` pinning the provider's ServiceAccount name to
`provider-helm`, plus a `ClusterRoleBinding` giving that fixed name the built-in
`cluster-admin` `ClusterRole` directly.

**What was tried first and why it didn't work**: reusing this repo's
`rbac.crossplane.io/aggregate-to-crossplane: "true"` label (the mechanism
`provider-kubernetes-secrets` uses) with a wildcard-rules `ClusterRole`, on the
theory that it would aggregate into whatever ServiceAccount Crossplane generates
for the `provider-helm` revision — the same way `provider-kubernetes` seems to gain
its secret-read access. Applying a test `DataPlane` claim failed immediately:
`cannot create resource "namespaces" ... at the cluster scope` for
`provider-helm`'s actual generated ServiceAccount. Inspecting the live cluster
showed why: the `crossplane` `ClusterRole` that label aggregates into is bound, via
`ClusterRoleBinding`, only to the `crossplane` core controller's own ServiceAccount
— not to any provider's. Each provider instead gets its own per-revision
auto-generated `crossplane:provider:<revision>:system` `ClusterRole`, scoped to its
own CRDs plus a fixed baseline (`secrets`/`configmaps`/`events`/`leases`) — which is
almost certainly why `provider-kubernetes` already works without
`provider-kubernetes-secrets` actually doing anything for it either; that
`ClusterRole` may have been redundant since it was added, not a mechanism this
feature could extend.

**Rationale for the fix**: A per-revision generated ServiceAccount name can't be
targeted by a stable `ClusterRoleBinding` directly, so the ServiceAccount name has
to be pinned first (`DeploymentRuntimeConfig`) before binding it. `cluster-admin`
(not a scoped role) matches the upstream example precisely because a `Release`'s
chart is arbitrary and unknown ahead of time.

**Alternatives considered**: None further — this is the vendor-documented pattern
for exactly this scenario, confirmed necessary by direct testing rather than
assumed.

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
