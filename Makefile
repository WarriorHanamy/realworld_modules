# =============================================================================
# VTOL Assembly Layer — L4T Version Selector & Build Orchestration
# =============================================================================
#
# Version selection (file-based, no shell quoting issues):
#   Create config/l4t_version.mk with e.g:  L4T_VERSION := r36.4.0
#   Or override on command line:  make docker-build-all L4T_VERSION=r36.4.0
#
# Default: r35.4.1 (20.04-R35.5.0 branch)
# =============================================================================

-include config/l4t_version.mk
include config/l4t_matrix.mk

L4T_VERSION ?= r35.4.1

# --- Branch & base image mapping per L4T version ---
# Linker containers (LIO, PX4) don't need CUDA; BHT needs CUDA for neural inference
ifeq ($(L4T_VERSION),r35.4.1)
  LINKER_BRANCH      := r35
  BHT_BRANCH         := r35
  LINKER_JETPACK_TAG := r36.4.0
  BHT_JETPACK_TAG    := r35.4.1
  LINKER_BASE_IMAGE  := nvcr.io/nvidia/l4t-jetpack
  BHT_BASE_IMAGE     := nvcr.io/nvidia/l4t-jetpack
else ifeq ($(L4T_VERSION),r36.2.0)
  LINKER_BRANCH      := main
  BHT_BRANCH         := track
  LINKER_JETPACK_TAG := r36.2.0
  BHT_JETPACK_TAG    := r36.4.0
  LINKER_BASE_IMAGE  := nvcr.io/nvidia/l4t-base
  BHT_BASE_IMAGE     := nvcr.io/nvidia/l4t-jetpack
else ifeq ($(L4T_VERSION),r36.4.0)
  LINKER_BRANCH      := main
  BHT_BRANCH         := track
  LINKER_JETPACK_TAG := r36.4.0
  BHT_JETPACK_TAG    := r36.4.0
  LINKER_BASE_IMAGE  := nvcr.io/nvidia/l4t-base
  BHT_BASE_IMAGE     := nvcr.io/nvidia/l4t-jetpack
endif

export L4T_VERSION

# --- Submodule paths ---
LINKER_DIR := linker
BHT_DIR    := vtol_behavior_manager

# --- Device connection (fixed convention) ---
DEVICE_IP    := 192.168.55.1
DEVICE_USER  := nv
SSH_KEY      := $(firstword $(wildcard ~/.ssh/id_ed25519 ~/.ssh/id_rsa))
SSH_OPTS     := $(if $(SSH_KEY),-i $(SSH_KEY),) -o StrictHostKeyChecking=no -o ConnectTimeout=5
SSH_DEVICE   := $(DEVICE_USER)@$(DEVICE_IP)

.PHONY: submodule-update
.PHONY: docker-build-linker-base docker-build-linker-lio docker-build-linker-px4
.PHONY: docker-build-linker docker-build-bht docker-build-all
.PHONY: check-host check-device check
.PHONY: info

# =============================================================================
# Submodule branch sync
# =============================================================================

submodule-update:
	@echo "[L4T: $(L4T_VERSION)] Syncing linker -> $(LINKER_BRANCH)..."
	git -C $(LINKER_DIR) fetch origin $(LINKER_BRANCH) && \
	  git -C $(LINKER_DIR) checkout $(LINKER_BRANCH)
	@echo "[L4T: $(L4T_VERSION)] Syncing vtol_behavior_manager -> $(BHT_BRANCH)..."
	git -C $(BHT_DIR) fetch origin $(BHT_BRANCH) && \
	  git -C $(BHT_DIR) checkout $(BHT_BRANCH)
	@echo "Done."

# =============================================================================
# Pre-build environment check
# =============================================================================

check-host:
	@echo "=== [host] L4T Version Knowledge ==="
	@echo "  L4T_VERSION          = $(L4T_VERSION)"
	@echo "  $(call l4t-matrix,$(L4T_VERSION),NAME)"
	@echo "  Ubuntu               = $(call l4t-matrix,$(L4T_VERSION),UBUNTU)"
	@echo "  CUDA                 = $(call l4t-matrix,$(L4T_VERSION),CUDA)"
	@echo "  ROS distro           = $(call l4t-matrix,$(L4T_VERSION),ROS_DISTRO)"
	@echo "  ROS source           = $(call l4t-matrix,$(L4T_VERSION),ROS_SOURCE)"
	@echo "  Tested               = $(call l4t-matrix,$(L4T_VERSION),TESTED)"
	@echo ""
	@echo "=== [host] NGC image tag check ==="
	@echo -n "  $(LINKER_BASE_IMAGE):$(LINKER_JETPACK_TAG) => "; \
	  docker manifest inspect $(LINKER_BASE_IMAGE):$(LINKER_JETPACK_TAG) >/dev/null 2>&1 \
	  && echo "EXISTS" || echo "NOT FOUND (check config/l4t_matrix.mk)"
	@echo -n "  $(BHT_BASE_IMAGE):$(BHT_JETPACK_TAG) => "; \
	  docker manifest inspect $(BHT_BASE_IMAGE):$(BHT_JETPACK_TAG) >/dev/null 2>&1 \
	  && echo "EXISTS" || echo "NOT FOUND (check config/l4t_matrix.mk)"

check-device:
	@echo "=== [device] SSH connectivity ==="
	@echo -n "  $(SSH_DEVICE) => "; \
	  ssh $(SSH_OPTS) $(SSH_DEVICE) "echo OK" 2>/dev/null \
	  && echo "REACHABLE" || (echo "UNREACHABLE (check USB link)" && false)
	@echo ""
	@echo "=== [device] Docker access ==="
	@echo -n "  sudo docker info => "; \
	  ssh $(SSH_OPTS) $(SSH_DEVICE) "sudo docker info --format '{{.ServerVersion}}'" 2>/dev/null \
	  && echo "OK" || (echo "FAILED (check sudo docker access)" && false)
	@echo ""
	@echo "=== [device] Docker BuildKit ==="
	@echo -n "  buildx version => "; \
	  ssh $(SSH_OPTS) $(SSH_DEVICE) "sudo docker buildx version 2>/dev/null" \
	  && echo "OK" || (echo "MISSING (install docker-buildx)" && false)
	@echo ""
	@echo "=== [device] Base image ==="
	@echo -n "  $(LINKER_BASE_IMAGE):$(LINKER_JETPACK_TAG) => "; \
	  ssh $(SSH_OPTS) $(SSH_DEVICE) "sudo docker image inspect $(LINKER_BASE_IMAGE):$(LINKER_JETPACK_TAG) >/dev/null 2>&1" \
	  && echo "CACHED" || echo "NOT CACHED (will pull during build)"
	@echo -n "  $(BHT_BASE_IMAGE):$(BHT_JETPACK_TAG) => "; \
	  ssh $(SSH_OPTS) $(SSH_DEVICE) "sudo docker image inspect $(BHT_BASE_IMAGE):$(BHT_JETPACK_TAG) >/dev/null 2>&1" \
	  && echo "CACHED" || echo "NOT CACHED (will pull during build)"
	@echo ""
	@echo "=== [device] Disk space ==="
	@ssh $(SSH_OPTS) $(SSH_DEVICE) "df -h / | awk 'NR==2{print \"  \" \$$3 \" used / \" \$$2 \" total (\" \$$5 \")\"}'"
	@echo ""
	@echo "=== [device] apt repos reachable ==="
	@ssh $(SSH_OPTS) $(SSH_DEVICE) "sudo apt-get update 2>&1 | tail -2" || \
	  (echo "  APT FAILED — check network proxy" && false)

check: check-host check-device

# =============================================================================
# Docker build targets (delegated to submodule Makefiles)
# =============================================================================

docker-build-linker-base:
	$(MAKE) -C $(LINKER_DIR) docker-build-base-jetson \
	  JETPACK_TAG=$(LINKER_JETPACK_TAG) \
	  L4T_BASE_IMAGE=$(LINKER_BASE_IMAGE)

docker-build-linker-lio:
	$(MAKE) -C $(LINKER_DIR) docker-build-lio-jetson \
	  JETPACK_TAG=$(LINKER_JETPACK_TAG) \
	  L4T_BASE_IMAGE=$(LINKER_BASE_IMAGE)

docker-build-linker-px4:
	$(MAKE) -C $(LINKER_DIR) docker-build-px4-connector-jetson \
	  JETPACK_TAG=$(LINKER_JETPACK_TAG) \
	  L4T_BASE_IMAGE=$(LINKER_BASE_IMAGE)

docker-build-linker: docker-build-linker-base docker-build-linker-lio docker-build-linker-px4

docker-build-bht:
	$(MAKE) -C $(BHT_DIR) docker-build-bht-jetson \
	  JETPACK_TAG=$(BHT_JETPACK_TAG) \
	  L4T_BASE_IMAGE=$(BHT_BASE_IMAGE)

docker-build-all: docker-build-linker docker-build-bht

# =============================================================================
# Info
# =============================================================================

info:
	@echo "L4T_VERSION            = $(L4T_VERSION)"
	@echo "  $(call l4t-matrix,$(L4T_VERSION),NAME)"
	@echo "  Ubuntu               = $(call l4t-matrix,$(L4T_VERSION),UBUNTU)"
	@echo "  CUDA                 = $(call l4t-matrix,$(L4T_VERSION),CUDA)"
	@echo "  ROS distro           = $(call l4t-matrix,$(L4T_VERSION),ROS_DISTRO)"
	@echo "  ROS source           = $(call l4t-matrix,$(L4T_VERSION),ROS_SOURCE)"
	@echo "  Tested               = $(call l4t-matrix,$(L4T_VERSION),TESTED)"
	@echo ""
	@echo "linker branch          = $(LINKER_BRANCH)"
	@echo "bht   branch           = $(BHT_BRANCH)"
	@echo "linker base image      = $(LINKER_BASE_IMAGE):$(LINKER_JETPACK_TAG)"
	@echo "bht   base image       = $(BHT_BASE_IMAGE):$(BHT_JETPACK_TAG)"
	@echo ""
	@echo "Targets:"
	@echo "  make check                 pre-flight environment validation"
	@echo "  make submodule-update      sync submodules to version branch"
	@echo "  make docker-build-linker   build LIO + PX4 connector containers"
	@echo "  make docker-build-bht      build neural behavior container"
	@echo "  make docker-build-all      build everything"
	@echo ""
	@echo "To switch L4T version:"
	@echo "  echo 'L4T_VERSION := r36.4.0' > config/l4t_version.mk"
