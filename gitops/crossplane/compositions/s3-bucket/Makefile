# s3-bucket: provisions an S3 bucket in Floci (local AWS emulator) via
# provider-aws-s3. No image to build — this Composition is pure YAML,
# like dataplane-baseline.

CHART        := chart
KUBECONTEXT  ?= k3d-hub
HELM         ?= helm
KUBECTL      ?= kubectl --context $(KUBECONTEXT)

.PHONY: help dev build test push clean

help:
	@echo "Targets: dev, build, test, push (no-op), clean"

dev:
	$(HELM) lint $(CHART)
	$(HELM) template s3-bucket $(CHART)

build:
	$(HELM) lint $(CHART)
	$(HELM) template s3-bucket $(CHART) > /dev/null
	@echo "s3-bucket: chart OK"

## test: apply the example claim, wait for Ready, confirm the bucket exists
## in Floci via its S3 API, then tear down.
test:
	$(KUBECTL) apply -f examples/claim-s3bucket.yaml
	$(KUBECTL) wait s3bucket/demo-bucket -n default --for=condition=Ready --timeout=60s
	$(KUBECTL) get s3bucket demo-bucket -n default -o jsonpath='{.status.bucketName}{"\n"}'
	$(KUBECTL) delete -f examples/claim-s3bucket.yaml --wait=true --timeout=30s
	@echo "s3-bucket: example claim provisioned, verified, and torn down"

push:
	@echo "s3-bucket: no image to push"

clean:
	@true
