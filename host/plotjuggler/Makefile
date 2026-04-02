DOCKER := docker
PLATFORM := linux/amd64
IMAGE_PREFIX ?= vtol

.PHONY: pj pj-push

pj:
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f plotjuggler.dockerfile \
		-t $(IMAGE_PREFIX)/plotjuggler:latest \
		--load \
		.

pj-push:
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f plotjuggler.dockerfile \
		-t $(IMAGE_PREFIX)/plotjuggler:latest \
		--push \
		.
