DOCKER := docker
PLATFORM := linux/arm64
IMAGE_PREFIX ?= vtol

.PHONY: lio lio-push calib calib-push

lio:
	$(DOCKER) run --rm --privileged tonistiigi/binfmt --install arm64 || true
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f dockerfiles/lio.dockerfile \
		-t $(IMAGE_PREFIX)/lio-jetson:latest \
		--load \
		.

lio-push:
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f dockerfiles/lio.dockerfile \
		-t $(IMAGE_PREFIX)/lio-jetson:latest \
		--push \
		.

calib:
	$(DOCKER) run --rm --privileged tonistiigi/binfmt --install arm64 || true
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f dockerfiles/calib_lidar_imu_init.dockerfile \
		-t $(IMAGE_PREFIX)/calib-lidar-imu-init-jetson:latest \
		--load \
		.

calib-push:
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f dockerfiles/calib_lidar_imu_init.dockerfile \
		-t $(IMAGE_PREFIX)/calib-lidar-imu-init-jetson:latest \
		--push \
		.
