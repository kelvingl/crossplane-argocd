# dataplane-cluster: classic Patch-and-Transform Composition (feature 003),
# Helm-packaged. No image to build — this Composition is pure YAML; the
# vcluster chart it installs is pulled by provider-helm at runtime, not
# built/pushed by this Makefile.

CHART        := chart
KUBECONTEXT  ?= k3d-hub
HELM         ?= helm
KUBECTL      ?= kubectl --context $(KUBECONTEXT)

.PHONY: help dev build test push clean

help:
	@echo "Targets: dev, build, test, push (no-op), clean"

## dev: fast feedback loop while editing templates — lint + render to stdout
dev:
	$(HELM) lint $(CHART)
	$(HELM) template dataplane-cluster $(CHART)

## build: validate the chart renders cleanly (what ArgoCD will do on sync)
build:
	$(HELM) lint $(CHART)
	$(HELM) template dataplane-cluster $(CHART) > /dev/null
	@echo "dataplane-cluster: chart OK"

## test: apply the example claim, wait for the vcluster to become Ready, remove it
test:
	$(KUBECTL) apply -f examples/claim-dataplane.yaml
	$(KUBECTL) wait dataplane/dataplane-cluster-test -n default --for=condition=Ready --timeout=300s
	@echo "dataplane-cluster: example claim Ready"
	$(KUBECTL) delete -f examples/claim-dataplane.yaml

## push: nothing to publish for this Composition — kept so root's push-all
## can loop over every composition uniformly.
push:
	@echo "dataplane-cluster: no image to push"

clean:
	@true
