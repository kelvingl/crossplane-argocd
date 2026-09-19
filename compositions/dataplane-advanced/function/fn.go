package main

import (
	"context"
	"fmt"

	"github.com/crossplane/function-sdk-go/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"
)

// managedByLabel/instanceLabel are the standardized labels this function
// applies to every resource it composes, so dataplanes provisioned through
// this Composition Function are easy to tell apart from the feature-001
// patch-and-transform baseline example.
const (
	managedByLabel = "app.kubernetes.io/managed-by"
	instanceLabel  = "app.kubernetes.io/instance"
	partOfLabel    = "app.kubernetes.io/part-of"

	defaultImage    = "nginxdemos/hello"
	defaultReplicas = int64(1)
)

// Function composes an advanced dataplane's resources.
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer

	log logging.Logger
}

// RunFunction is called by Crossplane once per reconcile of an
// XDataPlaneAdvanced composite resource.
func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {
	rsp := response.To(req, response.DefaultTTL)

	xr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get observed composite resource"))
		return rsp, nil
	}

	claimName := xr.Resource.GetLabels()["crossplane.io/claim-name"]
	if claimName == "" {
		// Fall back to the XR's own name if it wasn't created from a claim.
		claimName = xr.Resource.GetName()
	}

	spoke, err := xr.Resource.GetString("spec.parameters.spoke")
	if err != nil || spoke == "" {
		response.Fatal(rsp, errors.New("spec.parameters.spoke is required"))
		return rsp, nil
	}

	image, err := xr.Resource.GetString("spec.parameters.image")
	if err != nil || image == "" {
		image = defaultImage
	}

	replicas, err := xr.Resource.GetInteger("spec.parameters.replicas")
	if err != nil || replicas < 1 {
		replicas = defaultReplicas
	}

	config, err := xr.Resource.GetStringObject("spec.parameters.config")
	if err != nil {
		config = map[string]string{}
	}

	namespace := fmt.Sprintf("dp-%s", claimName)
	name := fmt.Sprintf("dataplane-%s", claimName)

	labels := map[string]any{
		managedByLabel: "dataplane-function",
		instanceLabel:  claimName,
		partOfLabel:    "argo-crossplane-lab",
	}

	desired := map[resource.Name]*resource.DesiredComposed{
		"namespace": newDesiredObject(spoke, map[string]any{
			"apiVersion": "v1",
			"kind":       "Namespace",
			"metadata": map[string]any{
				"name":   namespace,
				"labels": labels,
			},
		}),
		"configmap": newDesiredObject(spoke, map[string]any{
			"apiVersion": "v1",
			"kind":       "ConfigMap",
			"metadata": map[string]any{
				"name":      name + "-config",
				"namespace": namespace,
				"labels":    labels,
			},
			"data": stringMapToAny(config),
		}),
		"deployment": newDesiredObject(spoke, map[string]any{
			"apiVersion": "apps/v1",
			"kind":       "Deployment",
			"metadata": map[string]any{
				"name":      name,
				"namespace": namespace,
				"labels":    labels,
			},
			"spec": map[string]any{
				"replicas": replicas,
				"selector": map[string]any{
					"matchLabels": map[string]any{
						"app": name,
					},
				},
				"template": map[string]any{
					"metadata": map[string]any{
						"labels": mergeLabels(labels, map[string]any{"app": name}),
					},
					"spec": map[string]any{
						"containers": []any{
							map[string]any{
								"name":  "app",
								"image": image,
								"ports": []any{
									map[string]any{"containerPort": int64(80)},
								},
								"envFrom": []any{
									map[string]any{
										"configMapRef": map[string]any{"name": name + "-config"},
									},
								},
								"resources": map[string]any{
									"requests": map[string]any{
										"cpu":    "100m",
										"memory": "128Mi",
									},
									"limits": map[string]any{
										"cpu":    "250m",
										"memory": "256Mi",
									},
								},
							},
						},
					},
				},
			},
		}),
		"service": newDesiredObject(spoke, map[string]any{
			"apiVersion": "v1",
			"kind":       "Service",
			"metadata": map[string]any{
				"name":      name,
				"namespace": namespace,
				"labels":    labels,
			},
			"spec": map[string]any{
				"selector": map[string]any{"app": name},
				"ports": []any{
					map[string]any{"port": int64(80), "targetPort": int64(80)},
				},
			},
		}),
	}

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}

	response.Normalf(rsp, "composed %d resources for dataplane %q targeting spoke %q", len(desired), claimName, spoke).TargetComposite()

	return rsp, nil
}

// newDesiredObject wraps the supplied manifest as a provider-kubernetes
// Object targeting the named spoke's ProviderConfig, matching the same
// kubernetes.crossplane.io/v1alpha2 Object shape used by the baseline
// patch-and-transform Composition (feature 001).
func newDesiredObject(providerConfig string, manifest map[string]any) *resource.DesiredComposed {
	u := composed.New()
	u.SetUnstructuredContent(map[string]any{
		"apiVersion": "kubernetes.crossplane.io/v1alpha2",
		"kind":       "Object",
		"spec": map[string]any{
			"forProvider": map[string]any{
				"manifest": manifest,
			},
			"providerConfigRef": map[string]any{
				"name": providerConfig,
			},
		},
	})
	// provider-kubernetes Objects don't get an implicit readiness check the
	// way patch-and-transform resources do, so without this the XR (and the
	// claim) would report Ready=False forever even once every Object synced.
	return &resource.DesiredComposed{Resource: u, Ready: resource.ReadyTrue}
}

func stringMapToAny(m map[string]string) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func mergeLabels(maps ...map[string]any) map[string]any {
	out := map[string]any{}
	for _, m := range maps {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}
