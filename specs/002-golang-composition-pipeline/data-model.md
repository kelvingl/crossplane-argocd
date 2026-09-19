# Phase 1 Data Model: Golang Composition Function Pipeline

## Advanced Dataplane Request

Maps to the `AdvancedDataPlane` claim (Crossplane `Claim` kind for XRD
`XDataPlaneAdvanced`, `charts/dataplane-advanced/templates/xrd-dataplane-advanced.yaml`).
In practice, every instance is rendered by the tiny `dataplane-instance` chart from a
directory in the `dataplanes` repo (see "Dataplane Instance" below) rather than
hand-written, but the claim shape itself is what that chart templates.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `metadata.name` | string | yes | — | Request identity; drives the isolated namespace/resource names created in the target spoke, same convention as feature 001 (`dp-<name>`, `dataplane-<name>`). |
| `metadata.namespace` | string | yes | — | Hub namespace the claim lives in (the Helm release namespace chosen for `dataplane-instance`). |
| `spec.parameters.spoke` | string | yes | — | Name of the target Spoke Registration (`ProviderConfig`), identical semantics to feature 001. |
| `spec.parameters.image` | string | no | `nginxdemos/hello` | Container image run in the spoke workload. |
| `spec.parameters.replicas` | integer (≥1) | no | `1` | Replica count for the spoke workload. |
| `spec.parameters.config` | map[string]string | no | `{}` | Free-form key/value data rendered into the composed `ConfigMap` — the "richer than baseline" surface a Composition Function makes easy to add without new patch plumbing. |
| `status.conditions` | condition list | (system-managed) | — | Standard Crossplane `Ready`/`Synced` conditions, same contract as feature 001. |

**Validation rules** (enforced by the XRD's OpenAPI schema): `spec.parameters.spoke`
required; `spec.parameters.replicas`, if set, must be ≥ 1 — identical rules to
feature 001's `DataPlane`, so the two claim types stay easy to compare side by side.

**Relationships**: One Advanced Dataplane Request references exactly one Spoke
Registration by name (same loose-coupling-by-string as feature 001) and is rendered
by exactly one Dataplane Instance (below).

## Composition Function

Maps to a Crossplane `Function` resource (`pkg.crossplane.io/v1beta1`) installed by
the `dataplane-advanced` chart, plus the container image it references.

| Field | Type | Required | Description |
|---|---|---|---|
| `metadata.name` | string | yes | Referenced by the `Composition`'s `spec.pipeline[].functionRef.name`. |
| `spec.package` | string (OCI ref) | yes | Points at the private registry, e.g. `registry.registry.svc.cluster.local:5000/dataplane-function:<tag>` — never a public registry (constitution Technology Constraints). |

**Relationships**: Exactly one `Function` is referenced by exactly one pipeline step
in the `XDataPlaneAdvanced` `Composition`. The function's own source code (the Go
program implementing `RunFunction`) lives outside this data model, in the
`dataplane-function` Gogs repository — it is build-time input to the image, not a
cluster object.

## Private Image Registry

Not a Crossplane-managed resource — a plain GitOps-managed Deployment
(`registry/`), reachable at a stable in-cluster DNS name and (for pushes) an
external Ingress host.

| Field | Type | Description |
|---|---|---|
| in-cluster address | `registry.registry.svc.cluster.local:5000` | What `Function.spec.package` and any Pod `image:` field inside the hub resolve. |
| external address | `registry.127-0-0-1.nip.io` | What an operator's `docker push` targets from outside the cluster. |
| storage | `PersistentVolumeClaim` | Blob storage for pushed image layers/manifests; no external object storage in this lab. |

**Relationships**: Zero-to-many images may be pushed to the registry; the
Composition Function's `Function.spec.package` is the only reference this feature's
data model depends on being present and pullable.

## Composition Package (Helm Chart)

The unit ArgoCD installs/upgrades for a Composition, per the amended constitution.
Two exist after this feature: `dataplane-baseline` (re-packaging feature 001's
existing XRD/Composition unchanged) and `dataplane-advanced` (this feature's
XRD/Function/Composition).

| Field | Type | Description |
|---|---|---|
| `Chart.yaml` `name`/`version` | string | Chart identity; `version` bumps whenever `templates/` changes, so ArgoCD's Helm source shows a real diff on upgrade. |
| `values.yaml` | map | For `dataplane-baseline`, effectively empty (byte-for-byte rendering of the original manifests). For `dataplane-advanced`, holds the default `Function.spec.package` image ref/tag. |
| `templates/` | files | The actual XRD/Composition/Function manifests, moved from `crossplane/compositions/` (baseline) or newly authored (advanced). |

**Relationships**: Exactly one chart backs exactly one `gitops/apps/*.yaml`
Application's Helm source. `dataplane-instance` (below) is a separate, third chart —
it templates *claims*, not the Composition/XRD/Function that define the type.

## Dataplanes Repository

The new Gogs repository `dataplanes`; not a Kubernetes object, but the source of
truth an `ApplicationSet` reads.

| Field | Type | Description |
|---|---|---|
| top-level directory name | string | The dataplane's name — also used as the generated ArgoCD `Application` name and the rendered claim's `metadata.name`. |
| `<dir>/values.yaml` | file | The one values file per directory; schema matches `AdvancedDataPlane`'s `spec.parameters.*` — see `contracts/dataplane-instance-values.md`. |

**Validation rules**: A directory missing `values.yaml`, or one whose `values.yaml`
omits the required `spoke` key, fails only that directory's generated Application
(Helm template/values error) — it does not affect any other directory's Application,
satisfying spec FR-009.

## Dataplane Instance

The concept a directory + values file represents once discovered: one generated
ArgoCD `Application` (from `dataplanes-appset.yaml`) installing the
`dataplane-instance` chart with that directory's values, which in turn renders one
`AdvancedDataPlane` claim (see above).

| Field | Type | Description |
|---|---|---|
| name | string | = the directory name in the `dataplanes` repo. |
| target spoke | string | From `values.yaml`'s `spoke` key; must match a registered `ProviderConfig` name, identical contract to feature 001. |
| image / replicas / config | see Advanced Dataplane Request | Passed through 1:1 from `values.yaml` into the rendered claim's `spec.parameters.*`. |

**Relationships**: One Dataplane Instance ⇒ one generated ArgoCD `Application` ⇒ one
`AdvancedDataPlane` claim ⇒ (via the Composition Function pipeline) one isolated set
of composed resources in exactly one spoke — the same 1:1:1:1 chain feature 001 has,
just with an extra Git-directory layer in front of the claim so it never has to be
hand-written.
