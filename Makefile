COMPOSITIONS := dataplane-cluster dataplane-advanced s3-bucket
KUBECONTEXT  ?= k3d-hub
KUBECTL      ?= kubectl --context $(KUBECONTEXT)

.PHONY: help up down status build-all push-all release-all test-all dev-all clean-all $(COMPOSITIONS)

help:
	@echo "argo-crossplane lab"
	@echo ""
	@echo "Lab lifecycle:"
	@echo "  make up             - scripts/00-up.sh (create clusters, bootstrap Gogs+ArgoCD)"
	@echo "  make down           - scripts/99-teardown.sh (destroy everything)"
	@echo "  make status         - ArgoCD Applications + dataplane claims at a glance"
	@echo ""
	@echo "Compositions ($(COMPOSITIONS)):"
	@echo "  make build-all      - build (and validate) every composition"
	@echo "  make push-all       - push every composition's image(s) to the private registry"
	@echo "  make release-all    - build-all then push-all"
	@echo "  make test-all       - run each composition's test target against the live hub"
	@echo "  make dev-all        - fast inner-loop check for every composition"
	@echo "  make clean-all      - clean build artifacts for every composition"
	@echo ""
	@echo "  make build-<name>   - run a single target for one composition (build/push/"
	@echo "  make push-<name>      test/dev/clean/release), e.g. make release-dataplane-advanced"
	@echo "  make test-<name>"
	@echo "  make dev-<name>"
	@echo "  make clean-<name>"
	@echo "  make release-<name>  - build-<name> then push-<name>"

## --- Lab lifecycle -----------------------------------------------------

up:
	./scripts/00-up.sh

down:
	./scripts/99-teardown.sh

status:
	@echo "== ArgoCD Applications =="
	@$(KUBECTL) -n argocd get application
	@echo ""
	@echo "== dataplane-baseline claims =="
	@$(KUBECTL) get dataplane 2>/dev/null || true
	@echo ""
	@echo "== dataplane-advanced claims =="
	@$(KUBECTL) get advanceddataplane 2>/dev/null || true

## --- Compositions --------------------------------------------------------
## Every compositions/<name>/Makefile exposes the same target surface (dev,
## build, push, test, clean), so these just fan out over $(COMPOSITIONS).

define for-each-composition
	@for c in $(COMPOSITIONS); do \
		echo "==> $$c: $(1)"; \
		$(MAKE) -C compositions/$$c $(1) || exit 1; \
	done
endef

build-all:
	$(call for-each-composition,build)

push-all:
	$(call for-each-composition,push)

release-all: build-all push-all

test-all:
	$(call for-each-composition,test)

dev-all:
	$(call for-each-composition,dev)

clean-all:
	$(call for-each-composition,clean)

## make build-dataplane-advanced, make test-dataplane-baseline, etc.
release-%:
	$(MAKE) -C compositions/$* build
	$(MAKE) -C compositions/$* push

build-%:
	$(MAKE) -C compositions/$* build

push-%:
	$(MAKE) -C compositions/$* push

test-%:
	$(MAKE) -C compositions/$* test

dev-%:
	$(MAKE) -C compositions/$* dev

clean-%:
	$(MAKE) -C compositions/$* clean
