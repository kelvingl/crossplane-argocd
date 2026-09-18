# Phase 0 Research: Hub-and-Spoke Dataplane Provisioning

No `NEEDS CLARIFICATION` markers remained in the Technical Context — this feature
was already implemented before this plan was written retroactively, so "research"
here documents the decisions actually made and the alternatives they beat, rather
than resolving open unknowns.

## Decision: `provider-kubernetes` as the sole hub→spoke mechanism

**Decision**: Use the `crossplane-contrib/provider-kubernetes` provider, one
`ProviderConfig` per spoke (credentials via a kubeconfig `Secret`), and `Object`
managed resources to create raw manifests on the target spoke.

**Rationale**: It is the only OSS-available, general-purpose way to have Crossplane
manage arbitrary resources on a *different* cluster than the one it runs on, without
requiring a commercial/enterprise Crossplane feature. It keeps the hub as the single
control point (constitution Principle II) and needs nothing installed on the spoke.

**Alternatives considered**:
- **Crossplane multi-cluster / "environments" features** — not available in the OSS
  edition used here; would add a paid dependency for a lab.
- **Cluster API (CAPI)** — solves cluster *lifecycle* (creating/deleting clusters),
  not "provision arbitrary workloads onto an existing cluster from a control plane",
  which is what this feature needs; out of scope.
- **A second ArgoCD instance per spoke** — would violate Principle II (spokes running
  their own platform tooling) and duplicate the App-of-Apps structure per spoke for
  no benefit in a 2-spoke lab.

## Decision: Classic Composition (Patch-and-Transform), Crossplane v1.20.x

**Decision**: Pin Crossplane to the latest v1.x line and use the classic
`spec.resources` Composition style, not v2's namespaced XRs or the Composition
Functions pipeline.

**Rationale**: Matches constitution's Technology Constraints. Keeps the mechanism
(patches, `CombineFromComposite`, `FromCompositeFieldPath`) readable without needing
a function runtime (e.g. `function-patch-and-transform`) as an extra moving part in a
lab meant to teach the hub-and-spoke *pattern*, not Crossplane's newest authoring
model.

**Alternatives considered**:
- **Crossplane v2 + Composition Functions** — the modern recommended path, but adds a
  function runtime dependency and a steeper learning curve; deferred to a future,
  deliberate constitution amendment rather than adopted incidentally here.

## Decision: Spoke selection is a plain string field, not a label selector

**Decision**: `spec.parameters.spoke` is patched 1:1 into
`spec.providerConfigRef.name` on every composed `Object`. `ProviderConfig` names are
chosen to equal the spoke name (`spoke-01`, `spoke-02`).

**Rationale**: Deterministic and easy to reason about for a 2-spoke lab; satisfies
spec SC-002 ("retargeting requires changing exactly one field") and SC-004 (adding a
spoke needs no Composition change, since the Composition never enumerates spoke
names — it only patches whatever string it's given).

**Alternatives considered**:
- **`providerConfigRef` via label `policy: Selector`** — more flexible (e.g. "any
  healthy spoke in region X") but adds indirection this lab doesn't need yet; the
  plain-name approach can be migrated to a selector later without changing the XRD's
  external contract (`spec.parameters.spoke` stays a string either way).

## Decision: Per-claim namespace naming via `CombineFromComposite`

**Decision**: Each composed `Namespace`/`Deployment`/`Service` is named/namespaced as
`dp-<claim-name>` inside the target spoke, computed with a `CombineFromComposite`
patch on `metadata.name`.

**Rationale**: Satisfies spec FR-004/SC-005 (isolation between concurrent claims
targeting the same spoke) without requiring the operator to pick a namespace
themselves.

**Alternatives considered**:
- **Fixed namespace (e.g. always `dataplane-demo`)** — simplest, but two claims
  against the same spoke would collide, failing FR-004; rejected.

## Decision: Reconciliation, not immediate consistency, handles apply ordering

**Decision**: The `Namespace`, `Deployment`, and `Service` `Object`s are submitted
together with no explicit ordering; `provider-kubernetes` retries until the
`Deployment`/`Service` can be created inside the (possibly not-yet-existent)
namespace.

**Rationale**: Matches spec's edge case requirement that a request "keep retrying and
converge" rather than fail permanently; avoids introducing cross-resource
`dependsOn` complexity for a 3-resource composition where eventual convergence is a
few reconcile loops (seconds), not a real operational problem.

**Alternatives considered**:
- **Explicit readiness gates between composed resources** — Crossplane supports this,
  but it's unnecessary ceremony for 3 resources with a self-healing controller loop.
