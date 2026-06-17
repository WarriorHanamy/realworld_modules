# =============================================================================
# VTOL Assembly Layer — L4T Version Selector & Build Orchestration
# =============================================================================
#
# Version selection (file-based, no shell quoting issues):
#   Create config/l4t_version.mk with e.g:  L4T_VERSION := r36.4.0
#   Or override on command line:  make docker-build-all L4T_VERSION=r36.4.0
#
# Default: r35.5.0 (20.04-R35.5.0 branch)
# =============================================================================

-include config/l4t_version.mk

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

.PHONY: submodule-update
.PHONY: docker-build-linker-base docker-build-linker-lio docker-build-linker-px4
.PHONY: docker-build-linker docker-build-bht docker-build-all
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
	@echo "linker branch          = $(LINKER_BRANCH)"
	@echo "bht   branch           = $(BHT_BRANCH)"
	@echo "linker base image      = $(LINKER_BASE_IMAGE):$(LINKER_JETPACK_TAG)"
	@echo "bht   base image       = $(BHT_BASE_IMAGE):$(BHT_JETPACK_TAG)"
	@echo ""
	@echo "Targets:"
	@echo "  make submodule-update      sync submodules to version branch"
	@echo "  make docker-build-linker   build LIO + PX4 connector containers"
	@echo "  make docker-build-bht      build neural behavior container"
	@echo "  make docker-build-all      build everything"
	@echo ""
	@echo "To switch L4T version:"
	@echo "  echo 'L4T_VERSION := r36.4.0' > config/l4t_version.mk"
