# Phase 0 Research: Golang Composition Function Pipeline

No `NEEDS CLARIFICATION` markers remained in the Technical Context — this document
records the decisions taken to turn the spec's requirements into a concrete design,
and the alternatives each one beat.

## Decision: `function-sdk-go` gRPC server as the Composition Function runtime

**Decision**: Implement the advanced composition's logic as a Go program using
`crossplane-runtime`'s `function-sdk-go`, which exposes a gRPC `RunFunction` server
that Crossplane's function-pipeline runtime calls once per reconcile with the
composite's desired/observed state, returning the desired composed resources.

**Rationale**: It's the only supported way to write a Crossplane Composition
Function in Go; it keeps the "what gets composed" logic as ordinary, testable Go
code instead of a patch-and-transform YAML DSL, which is exactly the "more built-out
example" the spec asks for (FR-001).

**Alternatives considered**:
- **KCL or Python function runtimes** — Crossplane also supports these, but the spec
  explicitly asks for Golang.
- **Embedding logic in `provider-kubernetes` directly** — not possible; the provider
  only applies `Object` manifests, it has no composition/templating role.

## Decision: Additive Composition — new XRD, existing one untouched

**Decision**: Ship a new `XDataPlaneAdvanced` CompositeResourceDefinition / claim
`AdvancedDataPlane` (same API group `lab.example.org`) rather than modifying
`XDataPlane`/`DataPlane` from feature 001 in place.

**Rationale**: Constitution Principle IV requires the feature-001 example to stay
verified end-to-end; changing its Composition's mode in place risks regressing it
for no benefit, and the spec's own Assumptions section commits to this being
additive. A second XRD also makes the "richer resource set" comparison legible side
by side in the lab.

**Alternatives considered**:
- **Add a second `Composition` (function-pipeline) for the *same* `XDataPlane` XRD,
  selected via `compositionSelector`** — technically possible in Crossplane v1.x, but
  it complicates the claim contract (which Composition wins?) for no real benefit in
  a lab whose whole point is to show two patterns side by side.

## Decision: Composed resource set — Namespace, ConfigMap, Deployment (with
requests/limits), Service — same delivery mechanism (`provider-kubernetes` Objects)

**Decision**: The function returns the same kind of composed resources as the
existing example (Namespace, Deployment, Service, all wrapped as
`provider-kubernetes` `Object`s targeting the claim's chosen spoke), plus a
`ConfigMap` (workload configuration placeholder) and standardized
`resources.requests/limits` + labels/annotations on the `Deployment`.

**Rationale**: Satisfies FR-001's "richer than the baseline" bar without changing the
delivery mechanism — Principle II (hub-and-spoke isolation via
`provider-kubernetes` + `providerConfigRef.name`) applies identically to
function-composed resources as to patch-and-transform ones; the function computes
*what* `Object`s to submit, it never talks to a spoke API server itself.

**Alternatives considered**:
- **HorizontalPodAutoscaler** — mentioned as a "may include" option in the spec;
  deferred out of the first implementation slice to keep the function's first
  version small and reviewable; can be added later without changing the claim's
  external contract.

## Decision: Private registry = CNCF `distribution/distribution` (Docker Registry v2), deployed like Gogs

**Decision**: Run `registry:2` (the reference OCI Distribution implementation) as a
plain Deployment+Service+PVC+Ingress in the hub, GitOps-managed via a new
`gitops/apps/registry.yaml` Application (directory source, sync-wave 0 — same wave
as Gogs/Crossplane core, since the function image must exist before the advanced
Composition's chart can install a working `Function`), exposed inside the cluster at
`registry.registry.svc.cluster.local:5000` and outside via
`registry.127-0-0-1.nip.io` (same Traefik + `lab-ca-issuer` self-signed-CA pattern
already proven for ArgoCD/Gogs).

**Rationale**: `distribution/distribution` is the simplest possible OCI-compliant
registry — a single container, no database — matching this lab's "one moving part
per concern" style (same reasoning that picked Gogs over a heavier forge). Reusing
the existing Ingress+cert-manager pattern means zero new TLS/exposure mechanism to
learn.

**Alternatives considered**:
- **Harbor** — production-grade (RBAC, vulnerability scanning, UI) but far heavier
  than a lab needs; would itself need a database and several Deployments.
  **zot** — a lighter modern alternative, but `distribution/distribution` is the more
  widely known reference implementation and keeps the example maximally portable.
- **k3d's built-in `--registry-create`** — creates a registry container *outside* any
  k3d cluster (a sibling Docker container), which would violate Principle I (it isn't
  a Kubernetes object ArgoCD can reconcile) and Principle II framing (it's not
  "in the hub", it's beside all three clusters). Rejected in favor of an in-cluster
  Deployment.

## Decision: Helm packaging for every Composition, including the pre-existing one

**Decision**: Wrap feature 001's `XDataPlane`/`DataPlane` XRD+Composition into a
minimal Helm chart (`charts/dataplane-baseline/`) with no behavioral change to the
rendered manifests, and switch `gitops/apps/crossplane-compositions.yaml`'s source
from `directory` to `helm`. The new advanced Composition ships directly as a chart
(`charts/dataplane-advanced/`) from day one.

**Rationale**: Directly required by the amended constitution (v1.1.0: "Any
Composition... that ArgoCD installs or upgrades MUST be packaged and released as a
Helm chart") and by the spec's FR-005/FR-010 (Helm-only delivery, no regression to
the existing example). Wrapping rather than rewriting the existing manifests keeps
FR-010 (non-regression) low-risk — the chart's `templates/` are the same YAML,
byte-for-byte, just moved under a chart with an (initially unused) `values.yaml`.

**Alternatives considered**:
- **Leave the baseline Composition on `directory` source, only Helm-package the new
  one** — simpler short-term, but leaves the constitution amendment half-applied and
  the spec explicit about migrating existing directory-sourced Applications; rejected.

## Decision: Dataplanes repo → one Helm release per directory via `ApplicationSet` (git generator, `directories`)

**Decision**: A new `ApplicationSet` (`gitops/apps/dataplanes-appset.yaml`) uses the
`git` generator's `directories` mode against the new `dataplanes` Gogs repo (one
entry per top-level directory) to generate one ArgoCD `Application` per dataplane.
Each generated Application is a **multi-source** Application: source 1 is this
platform repo's `charts/dataplane-instance` Helm chart (a tiny chart templating one
`AdvancedDataPlane` claim), source 2 is the matching directory in the `dataplanes`
repo referenced as `$values`, with `helm.valueFiles: ['$values/<dir>/values.yaml']`.

**Rationale**: This is the standard ArgoCD pattern for "chart lives in repo A, values
live in repo B" (multi-source Applications, generally available since ArgoCD 2.6,
well inside the "stable" channel this lab already installs). It satisfies FR-008
(automatic discovery, no manual per-instance ArgoCD config) and SC-005 (adding an Nth
dataplane touches only its own directory — the `ApplicationSet` template itself never
changes) while still keeping the actual claim-rendering logic (the chart) inside the
one repo ArgoCD already trusts, per this plan's Structure Decision.

**Alternatives considered**:
- **One static ArgoCD `Application` per dataplane, hand-written** — exactly the
  "manual per-instance ArgoCD configuration" the spec's FR-008 rules out; rejected.
- **`ApplicationSet` git *files* generator (one `config.json`/`values.yaml` per file,
  flat) instead of *directories*** — the spec explicitly asks for "a folder named
  after the dataplane" (FR-006), so `directories` mode is the literal match; `files`
  mode would need a flat naming convention instead of real folders.
- **Put the chart itself inside the `dataplanes` repo (single-source Application per
  directory)** — would duplicate the chart into every future dataplanes-repo clone
  and re-introduce a second place ArgoCD needs `Repository` credentials for the same
  content; rejected in favor of the multi-source split.

## Decision: Function source and dataplane declarations live in their own Gogs repos; charts/registry manifests stay in the platform repo

**Decision**: Two brand-new, minimal Gogs repositories (`dataplane-function`,
`dataplanes`) hold only what the spec explicitly calls their own repo (FR-002,
FR-006). Everything ArgoCD directly installs (the registry manifests, both Helm
charts, the `ApplicationSet`) stays inside this platform repo.

**Rationale**: Matches the spec's Key Entities split exactly, while minimizing new
ArgoCD `Repository` Secrets (one per new Gogs repo the ApplicationSet/Applications
must read — two, not four) and avoiding a chicken-and-egg problem where the chart
that installs the `Function` resource would otherwise need to live in the same repo
whose *only* job is hosting unrelated Go source.

**Alternatives considered**:
- **One combined repo for function source + its chart** — would mean ArgoCD needs a
  `Repository` Secret for `dataplane-function` too (for the chart), and ties the
  function's *packaging* lifecycle to its *source* lifecycle unnecessarily; rejected.

## Decision: No registry authentication in v1; push happens from the operator's trusted local Docker

**Decision**: The registry Service has no auth configured; `docker push`/`pull`
against `registry.127-0-0-1.nip.io` (self-signed cert, same CA already trusted for
Gogs/ArgoCD) works directly from the operator's machine and from the hub cluster's
kubelets.

**Rationale**: Matches the spec's explicit out-of-scope call-out ("autenticação/RBAC
avançada do registry") and constitution Principle V — since no credential exists yet,
there is nothing that could accidentally be committed. If auth is added later, the
credential follows the same `.secrets/`/`Secret` pattern as spoke kubeconfigs.

**Alternatives considered**:
- **htpasswd basic auth from day one** — more realistic, but adds a credential to
  manage for zero benefit in a single-operator lab; deferred, documented as an
  Assumption in the spec.

## Decision: Building/publishing the function image is a manual/scripted step, not CI

**Decision**: `scripts/11-push-function-and-dataplanes-repos.sh` creates both Gogs
repos, pushes their initial content, and runs `docker build && docker push` for the
function image once, from the operator's machine. No webhook/CI pipeline is wired to
rebuild on every function-source commit.

**Rationale**: Directly matches the spec's Assumptions ("CI/CD... out of scope for
this feature... publishing a new image is a manual or scripted step for now, and
this gap is called out explicitly"). Building CI infra (a runner, a webhook receiver)
would be a feature of its own.

**Alternatives considered**:
- **Gogs webhook → some in-cluster build job** — real pattern, genuinely out of scope
  per the spec; left as a documented future feature, not attempted here.
