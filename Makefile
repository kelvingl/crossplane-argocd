COMPOSITIONS := dataplane-cluster s3-bucket
KUBECONTEXT  ?= k3d-hub
KUBECTL      ?= kubectl --context $(KUBECONTEXT)

.PHONY: help up down status build-all push-all release-all test-all dev-all clean-all $(COMPOSITIONS)

help:
	@echo "argo-crossplane lab"
	@echo ""
	@echo "Lab lifecycle:"
	@echo "  make up             - bootstrap/scripts/00-up.sh (create clusters, bootstrap Gogs+ArgoCD)"
	@echo "  make down           - bootstrap/scripts/99-teardown.sh (destroy everything)"
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
	@echo "  make push-<name>      test/dev/clean/release), e.g. make release-dataplane-cluster"
	@echo "  make test-<name>"
	@echo "  make dev-<name>"
	@echo "  make clean-<name>"
	@echo "  make release-<name>  - build-<name> then push-<name>"

## --- Lab lifecycle -----------------------------------------------------

up:
	./bootstrap/scripts/00-up.sh

down:
	./bootstrap/scripts/99-teardown.sh

status:
	@echo "== ArgoCD Applications =="
	@$(KUBECTL) -n argocd get application
	@echo ""
	@echo "== DataPlane claims (spokes) =="
	@$(KUBECTL) get dataplane 2>/dev/null || true

## --- Compositions --------------------------------------------------------
## Every gitops/crossplane/compositions/<name>/Makefile exposes the same
## target surface (dev, build, push, test, clean), so these just fan out
## over $(COMPOSITIONS).

COMPOSITIONS_DIR := gitops/crossplane/compositions

define for-each-composition
	@for c in $(COMPOSITIONS); do \
		echo "==> $$c: $(1)"; \
		$(MAKE) -C $(COMPOSITIONS_DIR)/$$c $(1) || exit 1; \
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

## make build-dataplane-cluster, make test-s3-bucket, etc.
release-%:
	$(MAKE) -C $(COMPOSITIONS_DIR)/$* build
	$(MAKE) -C $(COMPOSITIONS_DIR)/$* push

build-%:
	$(MAKE) -C $(COMPOSITIONS_DIR)/$* build

push-%:
	$(MAKE) -C $(COMPOSITIONS_DIR)/$* push

test-%:
	$(MAKE) -C $(COMPOSITIONS_DIR)/$* test

dev-%:
	$(MAKE) -C $(COMPOSITIONS_DIR)/$* dev

clean-%:
	$(MAKE) -C $(COMPOSITIONS_DIR)/$* clean
