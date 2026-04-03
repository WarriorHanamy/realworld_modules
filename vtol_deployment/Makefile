DOCKER := docker
PLATFORM := linux/arm64
IMAGE_PREFIX ?= vtol
IMAGE_SUFFIX ?= jetson
DATA_DIR ?= $(CURDIR)/data
ROOT_DIR := $(abspath $(CURDIR)/..)

BAG ?=
LAUNCH ?= mid360.launch
PLAY_RATE ?=

CALIB_IMAGE := $(IMAGE_PREFIX)/calib-lidar-imu-init-$(IMAGE_SUFFIX):latest
LIO_IMAGE := $(IMAGE_PREFIX)/lio-$(IMAGE_SUFFIX):latest
PX4_CONNECTOR_IMAGE := $(IMAGE_PREFIX)/px4-connector-$(IMAGE_SUFFIX):latest

.PHONY: docker-build-lio docker-build-px4-connector docker-build-calib docker-run-calib

docker-build-lio:
	$(DOCKER) run --rm --privileged tonistiigi/binfmt --install arm64 || true
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f $(CURDIR)/linker/dockerfiles/lio.dockerfile \
		-t $(LIO_IMAGE) \
		--load \
		$(ROOT_DIR)

docker-build-px4-connector:
	$(DOCKER) run --rm --privileged tonistiigi/binfmt --install arm64 || true
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f $(CURDIR)/linker/dockerfiles/px4_connector.dockerfile \
		-t $(PX4_CONNECTOR_IMAGE) \
		--load \
		$(ROOT_DIR)

docker-build-calib:
	$(DOCKER) run --rm --privileged tonistiigi/binfmt --install arm64 || true
	$(DOCKER) buildx build \
		--platform $(PLATFORM) \
		-f $(CURDIR)/linker/calibration/dockerfiles/calib_lidar_imu_init.dockerfile \
		-t $(CALIB_IMAGE) \
		--load \
		$(ROOT_DIR)

docker-run-calib:
ifndef BAG
	$(error BAG is required. Usage: make docker-run-calib BAG=calibration.bag)
endif
	@mkdir -p $(DATA_DIR)
	$(DOCKER) run --rm \
		--net=host \
		-v $(DATA_DIR):/data:rw \
		$(CALIB_IMAGE) \
		/usr/local/bin/calib_run.sh \
		$(if $(LAUNCH),--launch $(LAUNCH)) \
		$(if $(PLAY_RATE),--rate $(PLAY_RATE)) \
		/data/$(BAG)
