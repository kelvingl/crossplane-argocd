# dataplane-baseline: classic Patch-and-Transform Composition (feature 001),
# Helm-packaged. No image to build — this Composition is pure YAML.

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
	$(HELM) template dataplane-baseline $(CHART)

## build: validate the chart renders cleanly (what ArgoCD will do on sync)
build:
	$(HELM) lint $(CHART)
	$(HELM) template dataplane-baseline $(CHART) > /dev/null
	@echo "dataplane-baseline: chart OK"

## test: apply the two example claims and wait for them to become Ready
test:
	$(KUBECTL) apply -f ../../crossplane/examples/claim-dataplane-spoke-01.yaml
	$(KUBECTL) apply -f ../../crossplane/examples/claim-dataplane-spoke-02.yaml
	$(KUBECTL) wait dataplane/demo-01 -n default --for=condition=Ready --timeout=120s
	$(KUBECTL) wait dataplane/demo-02 -n default --for=condition=Ready --timeout=120s
	@echo "dataplane-baseline: both example claims Ready"

## push: nothing to publish for this Composition — kept so root's push-all
## can loop over every composition uniformly.
push:
	@echo "dataplane-baseline: no image to push"

clean:
	@true
