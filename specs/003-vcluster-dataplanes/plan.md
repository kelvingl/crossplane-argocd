# Implementation Plan: vcluster-Based Dataplane Clusters (XDataPlane Redefined)

**Branch**: `003-vcluster-dataplanes` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-vcluster-dataplanes/spec.md`

## Summary

Replace the two real, standalone k3d spoke clusters (`spoke-01`, `spoke-02`) with
vclusters (loft-sh/vcluster) running as workloads inside the `hub` k3d cluster,
provisioned declaratively by a Crossplane Composition. This Composition reuses the
XRD/claim names from feature 001-dataplane-provisioning (`XDataPlane`/`DataPlane`),
retiring that Composition's original meaning ("a workload inside an existing spoke")
in favor of a new one ("the spoke cluster itself"). A new Crossplane provider,
`crossplane-contrib/provider-helm`, installs the upstream vcluster Helm chart from
inside a `DataPlane` claim's Composition — no manifest reimplementation. Everything
that already addresses a spoke by name (`dataplane-advanced` claims, the
`dataplanes` repository's per-cluster `charts:`/`compositions:` entries, the ArgoCD
Cluster registration script) keeps working unmodified, because the vcluster's own
generated kubeconfig Secret is consumed directly by the same registration mechanism
that today consumes a k3d-derived kubeconfig — just sourced differently.

## Technical Context

**Language/Version**: No new application language — declarative Kubernetes/Helm YAML
(Composition, XRD, provider manifests) plus POSIX shell for the updated bootstrap
scripts. No Go code is introduced by this feature (unlike feature 002).

**Primary Dependencies**: `crossplane-contrib/provider-helm` (new — installs the
vcluster chart's `Release`), `loft-sh/vcluster` Helm chart (new, pulled from its
public upstream repository, consistent with how other third-party images already in
this lab are sourced), Crossplane v1.20.13 classic Patch-and-Transform mode (the new
`XDataPlane` Composition does not need function-pipeline — no per-claim procedural
logic is required beyond templating a `Release`), `provider-kubernetes` v1.3.1
(unchanged — still how a spoke, vcluster-backed or not, is reached for workload
placement), ArgoCD (unchanged — Cluster registration and the `dataplanes`
`ApplicationSet` both keep their existing shape).

**Storage**: The vcluster chart's own PVC (per-vcluster etcd/SQLite state, standard
vcluster chart default) inside the hub. No new credential storage pattern — the
vcluster's kubeconfig Secret is created by the chart itself in the hub, consumed
directly (no copy step) by `provider-kubernetes`'s `ProviderConfig` and by the
ArgoCD-cluster-registration script, exactly like the out-of-band Secrets this lab
already depends on.

**Testing**: No automated test suite (infra lab, unchanged posture). Validation is
manual/scripted: submit a `DataPlane` claim, confirm the vcluster comes up and is
reachable, confirm the two existing spokes migrate without touching any
`AdvancedDataPlane` claim or `dataplanes/<spoke>.yaml` file. See `quickstart.md`.

**Target Platform**: One real k3d cluster (`hub`) after this feature, down from
three. `spoke-01` and `spoke-02` become vclusters running as pods inside `hub`.

**Project Type**: Infrastructure / GitOps platform configuration — same category as
features 001 and 002, no user-facing runtime of its own.

**Performance Goals**: Matches spec SC-001/SC-003 — a new dataplane cluster
addressable within 5 minutes of its claim being applied; teardown within 5 minutes of
claim deletion.

**Constraints**: A `DataPlane` claim MUST result in a running vcluster with zero
manual steps beyond the Git commit (Principle I). The vcluster MUST run no platform
tooling of its own (Principle II). `provider-helm` is sanctioned only for installing
the vcluster chart, not as a general-purpose mechanism (Technology Constraints,
amended v1.2.0). Existing spoke-addressing contracts (`spec.parameters.spoke`,
`providerConfigRef.name`, ArgoCD `destination.name`) MUST NOT change.

**Scale/Scope**: Two dataplane clusters to migrate (`spoke-01`, `spoke-02`); the
mechanism MUST support an Nth new one the same way User Story 1 describes, with no
change to shared files beyond that Nth claim/declaration.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against constitution **v1.2.0** (amended 2026-09-24 specifically to permit
the pattern this feature needs).

| Principle | Status | Notes |
|---|---|---|
| I. GitOps-Only Changes | PASS | `provider-helm`, its `ProviderConfig`, and the redefined `XDataPlane` Composition are all Git-tracked under `crossplane/providers/`, `crossplane/config/`, `compositions/dataplane-cluster/` and reconciled by ArgoCD. The only imperative pieces left are the same class already exempted by Principle I: the hub's own k3d bootstrap, and the spoke-registration scripts (03/16) — now reading a vcluster-generated Secret instead of a `k3d kubeconfig get` file, same exemption, different source. |
| II. Hub-and-Spoke Isolation | PASS | A vcluster runs only the upstream vcluster control-plane/syncer images — no ArgoCD, Gogs, or Crossplane control plane inside it. It still only receives workload resources via `provider-kubernetes` `Object`s. It is created/destroyed exclusively via the `DataPlane` claim, per the v1.2.0 amendment. |
| III. App-of-Apps Structure | PASS | No new child `Application` objects are required: `provider-helm` and its `ProviderConfig` land inside the existing `crossplane-providers`/`crossplane-config` Applications (directory sources, already discovered); the `DataPlane` claim itself is emitted by the existing `dataplanes` `ApplicationSet`'s per-spoke wrapper chart (`charts/dataplane-cluster`), which already generates child `Application`s dynamically — this feature adds one more kind of child it generates. |
| IV. Composable, Testable Compositions | PASS (interpreted) | The `XDataPlane` Composition ships with its XRD/Composition and at least one real instance (`spoke-01`, `spoke-02`, migrated as part of this feature) verified end-to-end. Principle IV's literal wording ("resources observed running in the target spoke namespace") describes Compositions that populate an existing spoke; `XDataPlane` instead *creates* the spoke, so its equivalent bar is "the vcluster is `Ready` and addressable" — verified the same rigorous way (live inspection, not a demo), just against a different kind of resource. |
| V. Secrets Never Committed | PASS | The vcluster's kubeconfig Secret is generated inside the cluster by the chart itself — never authored or committed. `ProviderConfig`/ArgoCD Cluster registrations continue to reference it by name only. |

No unjustified violations — no Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/003-vcluster-dataplanes/
├── plan.md                      # This file
├── research.md                  # Phase 0 output
├── data-model.md                # Phase 1 output
├── quickstart.md                # Phase 1 output
├── contracts/
│   └── dataplane-claim.md       # Contract for a DataPlane claim / dataplanes/<spoke>.yaml
└── tasks.md                     # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
# argo-crossplane (this repo)
compositions/
├── dataplane-cluster/            # RENAMED from dataplane-baseline; content replaced
│   ├── Makefile
│   └── chart/
│       ├── Chart.yaml
│       ├── values.yaml           # default vcluster chart version/repo
│       └── templates/
│           ├── xrd-dataplane.yaml         # XDataPlane / DataPlane (same names, feature 001 content removed)
│           └── composition-dataplane-cluster.yaml   # classic P&T: one provider-helm Release
├── dataplane-advanced/           # UNCHANGED
└── s3-bucket/                    # UNCHANGED

crossplane/providers/
└── provider-helm.yaml            # NEW — Provider package + aggregated ClusterRole (RBAC
                                   #       for the vcluster chart's resources) + InjectedIdentity
                                   #       ClusterRoleBinding

crossplane/config/
└── providerconfig-helm-hub.yaml  # NEW — provider-helm ProviderConfig, credentials.source:
                                   #       InjectedIdentity (manages Releases in the hub itself)

charts/dataplane-cluster/         # EXISTING (from the prior dataplanes-repo architecture
├── Chart.yaml                    # change) — EXTENDED, not replaced
├── values.yaml                   # unchanged schema (cluster, charts[], compositions[])
└── templates/
    ├── _helpers.tpl              # unchanged
    ├── charts.yaml                # unchanged
    ├── compositions.yaml          # unchanged
    └── dataplane-claim.yaml       # NEW — always renders exactly one DataPlane claim
                                    #       named {{ .Values.cluster }}

gitops/apps/
├── crossplane-compositions.yaml  # EDITED — path: compositions/dataplane-cluster/chart
├── crossplane-providers.yaml     # UNCHANGED file, new content picked up automatically
│                                  # (directory source already includes crossplane/providers/)
└── crossplane-config.yaml        # UNCHANGED file, same reason for crossplane/config/

scripts/
├── 02-create-clusters.sh          # EDITED — creates only `hub`; spoke-01/spoke-02 removed
├── 03-register-spokes.sh          # RETIRED — superseded by Composition + updated script 16
└── 16-register-argocd-clusters.sh # EDITED — also (re)creates each spoke's
                                    #          provider-kubernetes ProviderConfig, now reading
                                    #          the vcluster-generated kubeconfig Secret instead
                                    #          of a k3d-derived local file

# dataplanes (separate Gogs repo — UNCHANGED shape)
dataplanes/spoke-01.yaml           # UNCHANGED content (still just "cluster: spoke-01" + its
dataplanes/spoke-02.yaml           # existing charts:/compositions: entries)
```

**Structure Decision**: Reuse every mechanism already built for the prior
`dataplanes/<spoke>.yaml` architecture (the `dataplanes` `ApplicationSet`, the
`charts/dataplane-cluster` wrapper chart, the registration scripts) rather than
inventing a parallel path for "cluster lifecycle" — the wrapper chart gains one more
always-rendered child (the `DataPlane` claim itself), so a spoke's existence and
what runs on it stay declared in the exact same file. Rename
`compositions/dataplane-baseline/` to `compositions/dataplane-cluster/` since its
purpose is now "create the cluster," not "baseline workload example" — its old
content (and the feature-001 example claims it produced) is removed, not migrated,
per the confirmed scope of this feature.

## Complexity Tracking

*No entries — Constitution Check has no unjustified violations.*
