DOCKER := docker
PLATFORM := linux/arm64
IMAGE_PREFIX ?= vtol

.PHONY: lio lio-push

lio:
	$(DOCKER) run --rm --privileged tonistiigi/binfmt --install arm64 || true
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f dockerfiles/lio.dockerfile \
		-t $(IMAGE_PREFIX)/lio:latest \
		--load \
		.

lio-push:
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f dockerfiles/lio.dockerfile \
		-t $(IMAGE_PREFIX)/lio:latest \
		--push \
		.
