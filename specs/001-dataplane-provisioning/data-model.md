# Phase 1 Data Model: Hub-and-Spoke Dataplane Provisioning

## Dataplane Request

Maps to the `DataPlane` claim (Crossplane `Claim` kind for XRD `XDataPlane`,
`crossplane/compositions/xrd-dataplane.yaml`), created by an operator in any
namespace of the **hub** cluster.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `metadata.name` | string | yes | — | Request identity; drives the isolated namespace name (`dp-<name>`) created in the target spoke. |
| `metadata.namespace` | string | yes | — | Hub namespace the claim lives in (e.g. `default`). Unrelated to the namespace created in the spoke. |
| `spec.parameters.spoke` | string | yes | — | Name of the target Spoke Registration. Must match an existing `ProviderConfig` name for the request to converge. |
| `spec.parameters.image` | string | no | `nginxdemos/hello` | Container image run in the spoke workload. |
| `spec.parameters.replicas` | integer (≥1) | no | `1` | Replica count for the spoke workload. |
| `status.conditions` | condition list | (system-managed) | — | Standard Crossplane `Ready`/`Synced` conditions; `Ready: True` means the composed resources exist and (for `Synced`) were successfully applied — this is how FR-005 ("report success from the hub") is satisfied. |

**Validation rules** (enforced by the XRD's OpenAPI schema):
- `spec.parameters.spoke` is required; requests without it are rejected by the API
  server before Crossplane ever reconciles them.
- `spec.parameters.replicas`, if set, must be ≥ 1.

**Relationships**: One Dataplane Request references exactly one Spoke Registration
by name (loose coupling — a string, not an object reference — so a request can be
created before or after its spoke is registered; it simply stays un-`Ready` until the
name resolves to a real `ProviderConfig`, satisfying the "retries and converges"
edge case in the spec).

## Spoke Registration

Maps to a `ProviderConfig` (`kubernetes.crossplane.io/v1alpha1`,
`crossplane/config/providerconfig-spoke-*.yaml`) plus its backing kubeconfig
`Secret`, both living in the hub's `crossplane-system` namespace.

| Field | Type | Required | Description |
|---|---|---|---|
| `metadata.name` | string | yes | The Spoke's identity; every Dataplane Request's `spec.parameters.spoke` must equal this value to target it. |
| `spec.credentials.source` | string | yes | Always `Secret` in this lab. |
| `spec.credentials.secretRef.{namespace,name,key}` | object | yes | Points at the out-of-band kubeconfig `Secret` (created by `scripts/03-register-spokes.sh`, never committed — constitution Principle V). |

**Validation rules**: None enforced by the XRD (a Spoke Registration is a Crossplane
platform resource, not a claim field) — an operator adding one follows the existing
two examples' shape.

**Relationships**: Zero-to-many Dataplane Requests may reference one Spoke
Registration by name at any given time; a Spoke Registration has no reference back to
the requests using it (satisfies spec User Story 3 — new spokes need no change to
request-side definitions).

## Composed Resources (implementation detail, not part of the request/registration contract)

Each Dataplane Request, once resolved, produces three `Object`
(`kubernetes.crossplane.io/v1alpha2`) managed resources in the hub, each of which
`provider-kubernetes` applies into the target spoke:

- `Namespace` named `dp-<request-name>`
- `Deployment` named `dataplane-<request-name>` in that namespace, running
  `spec.parameters.image` × `spec.parameters.replicas`
- `Service` named `dataplane-<request-name>` in that namespace, port 80 →
  container port 80

These are Crossplane-managed implementation details of the Composition
(`crossplane/compositions/composition-dataplane-k8s.yaml`) — operators interact only
with the Dataplane Request; see `contracts/dataplane-claim.md`.
