# Contract: `DataPlane` claim (`XDataPlane` Composition)

## Who consumes this

- A platform operator, submitting a claim directly (`kubectl apply` in a
  GitOps-tracked manifest) for ad-hoc use, **or**
- The `dataplanes` `ApplicationSet`, indirectly, via `charts/dataplane-cluster`
  rendering exactly one of these per `dataplanes/<spoke>.yaml` file in the
  `dataplanes` repository (the normal path — see
  `specs/003-vcluster-dataplanes/data-model.md`).

## Shape

```yaml
apiVersion: lab.example.org/v1alpha1
kind: DataPlane
metadata:
  name: spoke-01           # REQUIRED (k8s-native) — becomes the vcluster's Helm
                            # release name AND its namespace in the hub. Must be
                            # unique cluster-wide.
spec:
  parameters:
    kubernetesVersion: ""  # OPTIONAL — passed through to the vcluster chart if
                            # set; the chart's own default is used otherwise.
```

## Guarantees

1. **No parameters are required beyond the claim's name.** `spec: {}` (an empty but
   present `spec`, with `parameters` entirely absent) is valid and results in a
   working vcluster using the chart's own defaults — confirmed by testing: an
   entirely absent `spec` is rejected (`spec: Required value`), but an empty one is
   accepted.
2. **Readiness**: the claim reports `status.conditions[type=Ready].status: "True"`
   once the composed `provider-helm` `Release` is itself ready — no additional
   manual step confirms a vcluster is usable.
3. **Naming is the only collision guard.** Two claims with the same `metadata.name`
   cannot both exist (standard Kubernetes uniqueness) — this is intentional; it is
   the mechanism preventing the kind of naming collision documented in
   `docs/decisions.md` ADR-019.
4. **Deleting the claim tears down the vcluster** (the `Release` is deleted, which
   uninstalls the Helm release and removes its namespace's resources, including its
   kubeconfig Secret). It does **not** automatically remove the spoke's
   `ProviderConfig` or its ArgoCD Cluster Secret — those remain a manual step via the
   existing registration scripts, matching today's behavior for any spoke removal.

## What this claim does **not** do

- It does not place any workload inside the resulting vcluster — that remains the
  job of `dataplane-advanced` claims and/or `dataplanes/<spoke>.yaml`'s
  `charts:`/`compositions:` entries, addressing the new spoke by name exactly as
  they addressed a real k3d spoke before this feature.
- It does not register the resulting vcluster's `ProviderConfig` or ArgoCD Cluster —
  that is a separate, existing out-of-band step
  (`scripts/16-register-argocd-clusters.sh`), run once per new spoke name, same as
  before this feature.

## Relationship to `dataplanes/<spoke>.yaml`

The `dataplanes` repository's per-spoke file is the normal way this claim gets
created — see `specs/003-vcluster-dataplanes/data-model.md`. Its `cluster:` field
value is exactly this claim's `metadata.name`; no separate declaration is needed to
also request the cluster to exist.
