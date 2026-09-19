REGISTRY       ?= registry.127-0-0-1.nip.io
IMAGE_NAME     ?= dataplane-function
TAG            ?= v0.1.0

RUNTIME_IMAGE  := $(IMAGE_NAME)-runtime:$(TAG)
PACKAGE_IMAGE  := $(REGISTRY)/$(IMAGE_NAME):$(TAG)
PACKAGE_FILE   := $(IMAGE_NAME).xpkg

CROSSPLANE     ?= crossplane
DOCKER         ?= docker

.PHONY: all build image xpkg push clean

all: build push

## build: build the Go binary's runtime image and wrap it as a Crossplane xpkg
build: image xpkg

## image: build the function's runtime (controller) OCI image with Docker
image:
	$(DOCKER) build -t $(RUNTIME_IMAGE) .

## xpkg: package the runtime image as a Crossplane Function package (xpkg)
xpkg:
	$(CROSSPLANE) xpkg build \
		--package-root=package/ \
		--embed-runtime-image=$(RUNTIME_IMAGE) \
		-o $(PACKAGE_FILE)

## push: push the built xpkg to the private registry
push:
	$(CROSSPLANE) xpkg push \
		--insecure-skip-tls-verify \
		-f $(PACKAGE_FILE) \
		$(PACKAGE_IMAGE)

## clean: remove the built xpkg file
clean:
	rm -f $(PACKAGE_FILE)
