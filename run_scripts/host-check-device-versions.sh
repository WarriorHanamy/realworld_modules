#!/usr/bin/env bash
#
# host-check-device-versions.sh — Query Jetson device library versions
#
# Runs on the host machine.
# Connects to the Jetson via SSH (using sync_service/common.sh) and reports
# versions of NVIDIA/AI/ROS components installed on the device.
#
# Exit codes:
#   0  — Success (SSH succeeded, report printed)
#   1  — SSH/config failure or remote command unrecoverable error
#

set -eo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory and load remote execution helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../sync_service/common.sh"

if [[ ! -f "${COMMON_SH}" ]]; then
  echo "ERROR: Remote execution helpers not found: ${COMMON_SH}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${COMMON_SH}"

# ---------------------------------------------------------------------------
# Ensure SSH is initialized and reachable
# ---------------------------------------------------------------------------
if ! fn_nv_ensure_ssh; then
  echo "ERROR: Failed to initialize SSH configuration." >&2
  echo "       Check ${COMMON_SH} and ${SCRIPT_DIR}/../sync_service/sync_env" >&2
  exit 1
fi

echo ">>> Checking connectivity to ${SSH_TARGET}..."
if ! fn_nv_run_remote_bash "echo ok" >/dev/null 2>&1; then
  echo "ERROR: Cannot reach ${SSH_TARGET}. Verify network and SSH setup." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Remote probe helpers
# ---------------------------------------------------------------------------

# Run a remote command and print its stdout; on failure, print "unknown"
# Usage: probe "section title" "remote_command"
probe() {
  local title="$1"
  local cmd="$2"
  local out

  echo "=== ${title} ==="
  if out=$("${SSH_CMD[@]}" "bash -l -c $(printf '%q' "$cmd")" 2>/dev/null); then
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out"
    else
      printf 'detected: <empty output>\n'
    fi
  else
    printf 'status: unknown (command failed or not available)\n'
  fi
  echo ""
}

# Run a fallback chain; first successful command's stdout is printed.
# Usage: probe_with_fallback "section title" "cmd1" "cmd2" ...
probe_with_fallback() {
  local title="$1"
  shift
  local cmds=("$@")
  local i out

  echo "=== ${title} ==="
  for i in "${!cmds[@]}"; do
    if out=$("${SSH_CMD[@]}" "bash -l -c $(printf '%q' "${cmds[$i]}")" 2>/dev/null); then
      if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        echo ""
        return 0
      fi
    fi
  done
  printf 'status: missing (no detection method succeeded)\n'
  echo ""
}

# ---------------------------------------------------------------------------
# Main report
# ---------------------------------------------------------------------------
echo "=========================================="
echo " Jetson Device Version Report"
echo " Target: ${SSH_TARGET}"
echo "=========================================="
echo ""

# 1) JetPack / L4T
probe_with_fallback \
  "JetPack / L4T" \
  "dpkg-query -W -f='\${Package} \${Version}\n' nvidia-jetpack nvidia-l4t-core 2>/dev/null" \
  "cat /etc/nv_tegra_release 2>/dev/null" \
  "cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n' | head -1"

# 2) NVIDIA Driver
probe_with_fallback \
  "NVIDIA Driver" \
  "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null" \
  "cat /proc/driver/nvidia/version 2>/dev/null" \
  "modinfo nvidia 2>/dev/null | awk '/^version:/ {print \$2}'"

# Parse driver version and evaluate CUDA compatibility
parse_driver_info() {
  local raw ver branch cuda12_ok cuda13_ok

  # Collect raw version from first successful command
  raw=$("${SSH_CMD[@]}" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || \
    cat /proc/driver/nvidia/version 2>/dev/null || \
    modinfo nvidia 2>/dev/null | awk '/^version:/ {print \$2}'" | head -1 | tr -d '[:space:]')

  if [[ -z "$raw" ]]; then
    echo "=== NVIDIA Driver Compatibility ==="
    echo "raw: <unavailable>"
    echo "branch: unknown"
    echo "cuda_12_linux_requirement: unknown (driver unreachable)"
    echo "cuda_13_linux_requirement: unknown (driver unreachable)"
    echo ""
    return
  fi

  # Extract branch: first 3 digits before first dot or first 4 if it starts with 4-digit like 535+
  # Handle formats: 540.4.0b, 550.54.15, 535.129.03, 470.199.02, etc.
  if [[ "$raw" =~ ^([0-9]+)\. ]]; then
    ver="${BASH_REMATCH[1]}"
    # Branch naming: 470 -> R470, 525 -> R525, 535 -> R535, 540 -> R540, 550 -> R550
    branch="R${ver}"
  else
    branch="unknown"
  fi

  # Compare against CUDA requirements
  cuda12_ok="FAIL"
  cuda13_ok="FAIL"

  if [[ "$branch" =~ ^R([0-9]+)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    if [[ $num -ge 535 ]]; then
      cuda12_ok="PASS"
    fi
    if [[ $num -ge 580 ]]; then
      cuda13_ok="PASS"
    fi
  fi

  echo "=== NVIDIA Driver Compatibility ==="
  echo "raw: $raw"
  echo "branch: $branch"
  echo "cuda_12_linux_requirement: $cuda12_ok (requires R535+)"
  echo "cuda_13_linux_requirement: $cuda13_ok (requires R580+)"
  echo ""
}
parse_driver_info

# 3) GCC Compiler
probe_with_fallback \
  "GCC" \
  "gcc --version 2>/dev/null | head -1" \
  "dpkg-query -W -f='gcc \${Version}\n' gcc 2>/dev/null || true"

# 4) Python
probe_with_fallback \
  "Python" \
  "python3 --version 2>/dev/null"

# 5) GPU Compute Capability
probe_with_fallback \
  "GPU Compute Capability" \
  "nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null" \
  "python3 -c 'import torch; print(torch.cuda.get_device_capability())' 2>/dev/null || true"

# 6) CUDA
probe_with_fallback \
  "CUDA" \
  "nvcc --version 2>/dev/null" \
  "dpkg-query -W -f='\${Package} \${Version}\n' 'cuda-*' 'cuda-toolkit-*' 2>/dev/null" \
  "readlink -f /usr/local/cuda 2>/dev/null || true"

# 7) TensorRT
probe_with_fallback \
  "TensorRT" \
  "python3 -c 'import tensorrt as trt; print(\"Python TensorRT:\", getattr(trt, \"__version__\", \"unknown\"))' 2>/dev/null" \
  "dpkg-query -W -f='\${Package} \${Version}\n' 'tensorrt*' 'libnvinfer*' 2>/dev/null" \
  "trtexec --version 2>/dev/null"

# 8) TensorRT Installation Mode
# Deduce TensorRT installation mode from Debian packages
detect_tensorrt_mode() {
  local pkgs
  pkgs=$("${SSH_CMD[@]}" "dpkg -l 2>/dev/null | grep -E 'tensorrt|libnvinfer|python3-libnvinfer|libnvonnxparsers'" || true)

  local has_full=0 has_lean=0 has_dispatch=0

  if printf '%s\n' "$pkgs" | grep -qE 'tensorrt-dev|libnvinfer-dev|libnvinfer-bin|libnvonnxparsers-dev'; then
    has_full=1
  fi
  if printf '%s\n' "$pkgs" | grep -qE 'libnvinfer-lean|python3-libnvinfer-lean'; then
    has_lean=1
  fi
  if printf '%s\n' "$pkgs" | grep -qE 'libnvinfer-dispatch|python3-libnvinfer-dispatch'; then
    has_dispatch=1
  fi

  echo "=== TensorRT Installation Mode ==="
  printf 'full: %s\n' "$( [[ $has_full -eq 1 ]] && echo 'installed' || echo 'not installed' )"
  printf 'lean: %s\n' "$( [[ $has_lean -eq 1 ]] && echo 'installed' || echo 'not installed' )"
  printf 'dispatch: %s\n' "$( [[ $has_dispatch -eq 1 ]] && echo 'installed' || echo 'not installed' )"

  local effective="unknown"
  if [[ $has_full -eq 1 ]]; then
    effective="full (builder + runtime)"
  elif [[ $has_lean -eq 1 && $has_dispatch -eq 1 ]]; then
    effective="lean + dispatch (multi-mode)"
  elif [[ $has_lean -eq 1 ]]; then
    effective="lean runtime only"
  elif [[ $has_dispatch -eq 1 ]]; then
    effective="dispatch runtime only"
  else
    effective="runtime only (unknown variant)"
  fi
  printf 'effective capability: %s\n' "$effective"
  echo ""
}
detect_tensorrt_mode

# 9) cuDNN
probe_with_fallback \
  "cuDNN" \
  "dpkg-query -W -f='\${Package} \${Version}\n' 'libcudnn*' 2>/dev/null"

# 10) cuBLAS
probe_with_fallback \
  "cuBLAS" \
  "dpkg-query -W -f='\${Package} \${Version}\n' 'libcublas*' 'cublas*' 2>/dev/null" \
  "python3 -c 'import ctypes; lib=ctypes.CDLL(\"libcublas.so\"); print(\"cuBLAS via libcublas.so present\")' 2>/dev/null || true"

# 11) ROS 2
probe_with_fallback \
  "ROS 2" \
  "bash -lc 'source /opt/ros/humble/setup.bash >/dev/null 2>&1 && printf \"ROS_DISTRO=%s\\n\" \"\${ROS_DISTRO:-unknown}\" && ros2 --version 2>/dev/null'" \
  "printenv ROS_DISTRO 2>/dev/null"

# 12) ONNX Runtime
probe_with_fallback \
  "ONNX Runtime" \
  "python3 -c 'import onnxruntime as ort; print(ort.__version__)' 2>/dev/null"

# 13) PyTorch
probe_with_fallback \
  "PyTorch" \
  "python3 -c 'import torch; print(torch.__version__)' 2>/dev/null"

echo "=========================================="
echo " Report complete"
echo "=========================================="

exit 0
