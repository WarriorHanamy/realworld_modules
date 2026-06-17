# =============================================================================
# L4T Version Matrix — One-time NGC discovery, statically cached
#
# Generated: 2026-06-17
# How to refresh:
#   for tag in r35.1.0 r35.2.1 ... ; do
#     docker manifest inspect nvcr.io/nvidia/l4t-jetpack:$$tag >/dev/null 2>&1 \
#       && echo "  $$tag: YES" || echo "  $$tag: NO"
#   done
# =============================================================================

# --- NGC image tag availability (docker manifest inspect) ---
#
# l4t-jetpack:  r35.1.0  r35.2.1  r35.3.1  r35.4.1  |  r36.2.0  r36.3.0  r36.4.0
# l4t-base:     r35.1.0  r35.2.1                      |  r36.2.0

# --- Per-L4T-version knowledge ---

# R35.x — JetPack 5.x (Ubuntu 20.04 focal, kernel 5.10)
#   NVIDIA L4T apt repos: do NOT contain ros-humble-* packages
#   Public ROS2 focal repo: does NOT have Humble
#   ROS2 by using R36.x userland (l4t-jetpack:r36.4.0) on R35 kernel — safe for containers w/o CUDA
#   For CUDA workloads: use l4t-jetpack:r35.4.1, install ROS2 manually
L4T_MATRIX_r35.4.1_NAME        := JetPack 5.1.3
L4T_MATRIX_r35.4.1_UBUNTU      := focal
L4T_MATRIX_r35.4.1_KERNEL      := 5.10
L4T_MATRIX_r35.4.1_CUDA        := 11.4
L4T_MATRIX_r35.4.1_PYTHON      := 3.8
L4T_MATRIX_r35.4.1_JETPACK_IMG := r35.4.1
L4T_MATRIX_r35.4.1_BASE_IMG    := r35.2.1
L4T_MATRIX_r35.4.1_ROS_DISTRO  := humble
L4T_MATRIX_r35.4.1_ROS_SOURCE  := r36_userland  # LIO/PX4 use l4t-jetpack:r36.4.0 for ROS2
L4T_MATRIX_r35.4.1_TESTED      := yes

# R36.x — JetPack 6.x (Ubuntu 22.04 jammy, kernel 5.10)
#   Public ROS2 jammy repo: has ros-humble-* packages
#   NVIDIA L4T apt repos: also contain ROS2 packages
L4T_MATRIX_r36.4.0_NAME        := JetPack 6.0
L4T_MATRIX_r36.4.0_UBUNTU      := jammy
L4T_MATRIX_r36.4.0_KERNEL      := 5.10
L4T_MATRIX_r36.4.0_CUDA        := 12.6
L4T_MATRIX_r36.4.0_PYTHON      := 3.10
L4T_MATRIX_r36.4.0_JETPACK_IMG := r36.4.0
L4T_MATRIX_r36.4.0_BASE_IMG    := r36.4.0
L4T_MATRIX_r36.4.0_ROS_DISTRO  := humble
L4T_MATRIX_r36.4.0_ROS_SOURCE  := public_repo
L4T_MATRIX_r36.4.0_TESTED      := yes

# --- Convenience accessor macro ---
# Usage: $(call l4t-matrix,L4T_VERSION,key)  → value
#   $(call l4t-matrix,$(L4T_VERSION),JETPACK_IMG)
#   $(call l4t-matrix,$(L4T_VERSION),ROS_DISTRO)
l4t_matrix_ref = L4T_MATRIX_$(1)_$(2)
l4t-matrix     = $(value $(call l4t_matrix_ref,$(1),$(2)))
