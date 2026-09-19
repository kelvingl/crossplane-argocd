# dataplane-advanced: Composition Function pipeline (Go function + XRD +
# Composition), plus the tiny instance-chart used to render one claim.
# Delegates the actual image build/package/push to function/Makefile — this
# Makefile is the composition-level entry point (chart + function together).

CHART          := chart
INSTANCE_CHART := instance-chart
KUBECONTEXT    ?= k3d-hub
HELM           ?= helm
KUBECTL        ?= kubectl --context $(KUBECONTEXT)
TAG            ?= v0.1.1
TEST_NAME      := dataplane-advanced-makefile-test
TEST_SPOKE     ?= spoke-01

.PHONY: help dev build push test clean function-build function-push chart-build

help:
	@echo "Targets:"
	@echo "  dev           - go vet/build the function locally (fast feedback, no image)"
	@echo "  build         - build+package the function image (xpkg) and validate both charts"
	@echo "  push          - push the built function xpkg to the private registry (TAG=$(TAG))"
	@echo "  test          - install a throwaway claim via instance-chart, wait Ready, uninstall"
	@echo "  clean         - remove build artifacts in function/"

## dev: fastest inner loop while editing the function — just compile-check it
dev:
	$(MAKE) -C function build_go

## build: function image+xpkg (via function/Makefile) + lint/render both charts
build: function-build chart-build

function-build:
	$(MAKE) -C function build TAG=$(TAG)

## push: publish the function image built by `make build`
push: function-push

function-push:
	$(MAKE) -C function push TAG=$(TAG)

chart-build:
	$(HELM) lint $(CHART)
	$(HELM) template dataplane-advanced $(CHART) > /dev/null
	$(HELM) lint $(INSTANCE_CHART) --set spoke=$(TEST_SPOKE)
	$(HELM) template $(TEST_NAME) $(INSTANCE_CHART) --set spoke=$(TEST_SPOKE) > /dev/null
	@echo "dataplane-advanced: both charts OK"

## test: render+install a real, throwaway AdvancedDataPlane claim against the
## hub, confirm it reaches Ready, then tear it down. Requires the
## crossplane-compositions-advanced Application (XRD/Function/Composition)
## already synced, and the function image already pushed.
test:
	$(HELM) upgrade --install $(TEST_NAME) $(INSTANCE_CHART) \
		--kube-context $(KUBECONTEXT) --namespace default \
		--set spoke=$(TEST_SPOKE) --set image=nginxdemos/hello --set replicas=1
	$(KUBECTL) wait advanceddataplane/$(TEST_NAME) --for=condition=Ready --timeout=120s
	@echo "dataplane-advanced: test claim reached Ready — tearing down"
	$(HELM) uninstall $(TEST_NAME) --kube-context $(KUBECONTEXT) --namespace default

clean:
	$(MAKE) -C function clean
