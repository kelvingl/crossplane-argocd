# Contract: `DataPlane` Claim (Dataplane Request)

The interface this feature exposes to operators is a single Kubernetes custom
resource, applied to the **hub** cluster. This is the only contract surface —
operators never interact with a spoke directly (constitution Principle II).

- **Group/Version/Kind**: `lab.example.org/v1alpha1`, `DataPlane` (claim kind of
  `CompositeResourceDefinition` `xdataplanes.lab.example.org`, defined in
  `crossplane/compositions/xrd-dataplane.yaml`)
- **Scope**: Namespaced, in the hub cluster only.

## Request shape

```yaml
apiVersion: lab.example.org/v1alpha1
kind: DataPlane
metadata:
  name: <string>          # required — drives the isolated namespace `dp-<name>` in the spoke
  namespace: <string>     # required — hub namespace, e.g. "default"
spec:
  compositionRef:
    name: xdataplanes.lab.example.org
  parameters:
    spoke: <string>        # required — must match a registered Spoke Registration name
    image: <string>        # optional — default "nginxdemos/hello"
    replicas: <integer>    # optional — default 1, must be >= 1
```

See `crossplane/examples/claim-dataplane-spoke-01.yaml` and
`crossplane/examples/claim-dataplane-spoke-02.yaml` for concrete, runnable examples.

## Response shape (status)

```yaml
status:
  conditions:
    - type: Synced
      status: "True" | "False"   # composed resources were successfully applied
    - type: Ready
      status: "True" | "False"   # composed resources report ready
```

Consumers (operators, or automation) determine success per spec FR-005 by watching
for `Ready: "True"`:

```bash
kubectl --context k3d-hub get dataplane <name> -n <namespace> -o \
  jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

## Error / edge-case behavior

| Scenario | Observable behavior |
|---|---|
| `spec.parameters.spoke` names an unregistered spoke | `Ready` stays `"False"`; the composed `Object` resources report a `providerConfigRef` resolution error in their own `status.conditions` (inspectable via `kubectl describe object -l crossplane.io/composite=<xr-name>`). No resources are created anywhere. |
| Two requests target the same spoke | Each gets its own `dp-<name>` namespace; no collision (spec FR-004/SC-005). |
| Target spoke temporarily unreachable | `Ready` stays `"False"`; Crossplane's managed-resource reconciler retries with backoff and converges once the spoke is reachable again — no operator action required. |
| Request deleted | Crossplane deletes the composed `Object`s, which in turn delete the `Namespace` (cascading the `Deployment`/`Service` with it) from the spoke. |

## Backward compatibility

Adding a new Spoke Registration (a new `ProviderConfig`) never changes this
contract — `spec.parameters.spoke` is a free-form string compared against whatever
`ProviderConfig` names exist at reconcile time (spec SC-004).
