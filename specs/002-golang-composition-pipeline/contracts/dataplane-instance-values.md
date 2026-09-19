# Contract: Dataplane Instance (`dataplanes` repo directory → `values.yaml`)

The interface this feature exposes to operators is **not** a Kubernetes resource
directly — it is a Git directory in the `dataplanes` Gogs repository. This is the
only contract surface an operator touches for User Stories 1 and 3; ArgoCD's
`ApplicationSet` (`gitops/apps/dataplanes-appset.yaml`) turns it into a Helm release
of the `dataplane-instance` chart, which renders the `AdvancedDataPlane` claim
described in `data-model.md`.

- **Repository**: `dataplanes` (Gogs, `http://gogs.gogs.svc.cluster.local:3000/gitadmin/dataplanes.git`)
- **Unit of declaration**: one top-level directory per dataplane; directory name =
  dataplane name.
- **Required file**: `<dataplane-name>/values.yaml`

## Directory shape

```text
dataplanes/
├── demo-01/
│   └── values.yaml
├── demo-02/
│   └── values.yaml
└── <your-dataplane-name>/
    └── values.yaml
```

## `values.yaml` shape

```yaml
spoke: <string>            # required — must match a registered Spoke Registration name (e.g. spoke-01)
image: <string>            # optional — default "nginxdemos/hello"
replicas: <integer>        # optional — default 1, must be >= 1
config: {}                 # optional — free-form key/value map rendered into the composed ConfigMap
```

See `demo-01/values.yaml` and `demo-02/values.yaml` (pushed by
`scripts/11-push-function-and-dataplanes-repos.sh`) for concrete, runnable examples
— one per existing spoke, mirroring feature 001's two example claims.

## Response shape (how to observe success)

There is no `status` on a directory — observe the generated `Application` and the
claim it renders:

```bash
# 1. Confirm ArgoCD discovered the directory and created an Application for it
kubectl --context k3d-hub -n argocd get application dataplane-<name>

# 2. Confirm the rendered claim reports Ready
kubectl --context k3d-hub get advanceddataplane <name> -o \
  jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# 3. Confirm the resources landed in the declared spoke
kubectl --context k3d-spoke-0N -n dp-<name> get deploy,svc,cm
```

## Error / edge-case behavior

| Scenario | Observable behavior |
|---|---|
| `spoke` names an unregistered spoke | Same as feature 001: the generated `AdvancedDataPlane`'s `Ready` condition stays `"False"`; composed `Object`s report a `providerConfigRef` resolution error. |
| `values.yaml` missing or malformed (e.g. missing `spoke`) | Only that dataplane's generated `Application` fails to sync (Helm template/values error surfaced in ArgoCD); every other dataplane's `Application` is unaffected (spec FR-009). |
| Two directories target the same spoke | Each renders its own isolated `dp-<name>` namespace in that spoke; no collision. |
| A directory is renamed | Treated as removing the old dataplane (its `Application`/claim/resources are pruned) and adding a new one under the new name — not an in-place rename of running resources. |
| A directory is deleted | The `ApplicationSet` removes the generated `Application`; ArgoCD prunes the Helm release, which deletes the `AdvancedDataPlane` claim, cascading deletion of its composed resources from the spoke. |

## Backward compatibility

Adding a new registered spoke never changes this contract — `spoke` is a free-form
string compared against whatever `ProviderConfig` names exist at reconcile time,
identical to feature 001's SC-004. Adding an Nth dataplane directory never requires
touching `dataplanes-appset.yaml`, `charts/dataplane-instance/`, or any other
dataplane's directory (spec SC-005).
