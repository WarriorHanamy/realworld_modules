DOCKER := docker
PLATFORM := linux/arm64
IMAGE_PREFIX ?= vtol
IMAGE_SUFFIX ?= jetson

# Deployment configuration (fixed convention, same as linker/Makefile)
HOST_IP := 192.168.55.100
DEVICE_IP := 192.168.55.1
DEVICE_USER := nv
IMAGE_DIR := /tmp/vtol-images
REMOTE_DIR := /tmp/vtol-images
SSH_KEY := ~/.ssh/id_ed25519
SSH_OPTS := $(if $(wildcard $(SSH_KEY)),-i $(SSH_KEY),)

BRINGUP_IMAGE := $(IMAGE_PREFIX)/bringup-$(IMAGE_SUFFIX):latest
ROS2_BASE_IMAGE := $(IMAGE_PREFIX)/l4t-ros2-base-$(IMAGE_SUFFIX):latest

BRINGUP_REMOTE_BUILD_DIR := $(REMOTE_DIR)/bringup
BRINGUP_CONTEXT_FILES := Dockerfile bringup

# ==============================================================================
# Shipping macro
# ==============================================================================
define ship-context-to-device
	@ssh $(SSH_OPTS) $(DEVICE_USER)@$(DEVICE_IP) "rm -rf $(1) && mkdir -p $(1)"
	@rsync -avzR -e "ssh $(SSH_OPTS)" $(2) $(DEVICE_USER)@$(DEVICE_IP):$(1)/
endef

# ==============================================================================
# Build targets
# ==============================================================================

.PHONY: docker-build-bringup-jetson
docker-build-bringup-jetson: check-network
	@echo "[1/2] Shipping build context to $(DEVICE_USER)@$(DEVICE_IP)..."
	$(call ship-context-to-device,$(BRINGUP_REMOTE_BUILD_DIR),$(BRINGUP_CONTEXT_FILES))
	@echo "[2/2] Building bringup image on Jetson..."
	@ssh $(SSH_OPTS) $(DEVICE_USER)@$(DEVICE_IP) \
		"cd $(BRINGUP_REMOTE_BUILD_DIR) && \
		 docker build --network=host \
		   -f Dockerfile \
		   --build-arg BASE_IMAGE=$(ROS2_BASE_IMAGE) \
		   -t $(BRINGUP_IMAGE) ."

.PHONY: docker-build-bringup-jetson-force
docker-build-bringup-jetson-force: check-network
	@echo "[1/2] Shipping build context to $(DEVICE_USER)@$(DEVICE_IP)..."
	$(call ship-context-to-device,$(BRINGUP_REMOTE_BUILD_DIR),$(BRINGUP_CONTEXT_FILES))
	@echo "[2/2] Building bringup image with --pull on Jetson..."
	@ssh $(SSH_OPTS) $(DEVICE_USER)@$(DEVICE_IP) \
		"cd $(BRINGUP_REMOTE_BUILD_DIR) && \
		 docker build --network=host --pull \
		   -f Dockerfile \
		   -t $(BRINGUP_IMAGE) ."

.PHONY: docker-run-bringup-jetson-monitor
docker-run-bringup-jetson-monitor:
	$(DOCKER) run --rm \
		--net=host \
		--ipc=host \
		-e ROS_DOMAIN_ID=30 \
		-e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
		$(BRINGUP_IMAGE) \
		bash /home/ros/bringup/scripts/monitor.sh

.PHONY: docker-run-bringup-jetson-shell
docker-run-bringup-jetson-shell:
	$(DOCKER) run --rm -it \
		--net=host \
		--ipc=host \
		-e ROS_DOMAIN_ID=30 \
		-e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
		--entrypoint bash \
		$(BRINGUP_IMAGE)

# ==============================================================================
# Deployment targets
# ==============================================================================

.PHONY: docker-deploy-bringup-jetson
docker-deploy-bringup-jetson: check-network
	@echo "[1/2] Saving bringup image locally..."
	@mkdir -p $(IMAGE_DIR)
	$(DOCKER) save $(BRINGUP_IMAGE) | ssh $(SSH_OPTS) $(DEVICE_USER)@$(DEVICE_IP) "docker load"
	@echo "[2/2] Bringup image deployed."

# ==============================================================================
# Network check
# ==============================================================================

.PHONY: check-network
check-network:
	@echo "[INFO] Checking network convention..."
	@echo "[INFO] Host IP: $(HOST_IP)"
	@echo "[INFO] Device IP: $(DEVICE_IP)"
	@if ! ip addr show | grep -q "inet $(HOST_IP)/"; then \
		echo "[ERROR] Host does not have IP $(HOST_IP)"; \
		echo "[ERROR] This is a deployment convention — host must have $(HOST_IP)"; \
		exit 1; \
	fi
	@echo "[INFO] Host IP $(HOST_IP) found"
	@if ! ping -c 2 -W 3 $(DEVICE_IP) >/dev/null 2>&1; then \
		echo "[ERROR] Cannot reach device at $(DEVICE_IP)"; \
		echo "[ERROR] Check physical connection and device power"; \
		exit 1; \
	fi
	@echo "[INFO] Device $(DEVICE_IP) reachable"
	@echo "[INFO] Network convention check passed"

# ==============================================================================
# Utilities
# ==============================================================================

.PHONY: help
help:
	@echo "Bringup Makefile"
	@echo ""
	@echo "Build:"
	@echo "  docker-build-bringup-jetson         Build bringup image on device (SSH)"
	@echo "  docker-build-bringup-jetson-force   Rebuild with --pull (refresh base)"
	@echo ""
	@echo "Run:"
	@echo "  docker-run-bringup-jetson-monitor   Run monitor script on local Docker"
	@echo "  docker-run-bringup-jetson-shell     Interactive shell in bringup container"
	@echo ""
	@echo "Deploy:"
	@echo "  docker-deploy-bringup-jetson        Deploy bringup image to device"
	@echo ""
	@echo "Prerequisites:"
	@echo "  $(ROS2_BASE_IMAGE) must exist on device (build via linker/Makefile)"
	@echo "  Device must be reachable at $(DEVICE_IP)"
