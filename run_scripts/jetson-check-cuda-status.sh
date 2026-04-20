#!/usr/bin/env bash
#
# jetson-check-cuda-status.sh -- Compare CUDA stack versions: container vs native
#
# Runs directly on the Jetson device.
# Launches a Docker container with --gpus all, collects CUDA/cuDNN/cuBLAS/Python
# versions inside it, queries the same on the native system, prints a comparison.
#
# Usage:
#   ./run_scripts/jetson-check-cuda-status.sh
#   JETPACK_TAG=r36.4.0 ./run_scripts/jetson-check-cuda-status.sh
#
# Environment:
#   JETPACK_TAG   L4T JetPack image tag (default: r36.4.0)
#
# Exit codes:
#   0  -- Report printed
#   1  -- Docker or dependency failure
#

set -eo pipefail

JETPACK_TAG="${JETPACK_TAG:-r36.4.0}"
CONTAINER_IMAGE="nvcr.io/nvidia/l4t-jetpack:${JETPACK_TAG}"

# ---------------------------------------------------------------------------
# Detection: CUDA Toolkit (major.minor)
# ---------------------------------------------------------------------------
detect_cuda_toolkit() {
  local v
  # 1) version.json via python
  v=$(python3 -c "
import json,sys
try:
  d=json.load(open('/usr/local/cuda/version.json'))
  print(d.get('cuda',{}).get('version',''))
except: sys.exit(1)
" 2>/dev/null)
  [[ -n "$v" ]] && echo "${v%.*}" && return
  # 2) nvcc
  v=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')
  [[ -n "$v" ]] && echo "$v" && return
  # 3) version.txt
  v=$(sed -n 's/.*CUDA Version \([0-9]*\.[0-9]*\).*/\1/p' /usr/local/cuda/version.txt 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return
  # 4) cuda symlink path
  v=$(readlink -f /usr/local/cuda 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | tail -1)
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

# ---------------------------------------------------------------------------
# Detection: CUDA Runtime (full x.y.z)
# ---------------------------------------------------------------------------
detect_cuda_runtime() {
  local v
  # 1) version.json: cuda_cudart.version
  v=$(python3 -c "
import json,sys
try:
  d=json.load(open('/usr/local/cuda/version.json'))
  print(d.get('cuda_cudart',{}).get('version',''))
except: sys.exit(1)
" 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return
  # 2) nvcc
  v=$(nvcc --version 2>/dev/null | sed -n 's/.*V\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
  [[ -n "$v" ]] && echo "$v" && return
  # 3) version.txt
  v=$(sed -n 's/.*CUDA Version \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' /usr/local/cuda/version.txt 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

# ---------------------------------------------------------------------------
# Detection: Python
# ---------------------------------------------------------------------------
detect_python() {
  local v
  v=$(python3 --version 2>/dev/null | awk '{print $2}')
  [[ -n "$v" ]] && echo "$v" && return
  v=$(python --version 2>/dev/null | awk '{print $2}')
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

# ---------------------------------------------------------------------------
# Detection: cuDNN -- direct library check first
# ---------------------------------------------------------------------------
detect_cudnn() {
  local so_path v

  # 1) ldconfig
  so_path=$(ldconfig -p 2>/dev/null | grep 'libcudnn.so ' | awk '{print $NF}' | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" 2>/dev/null | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -z "$v" ]] && v=$(basename "$so_path" | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 2) find files
  so_path=$(find /usr -name 'libcudnn.so*' -type f 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(basename "$so_path" | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 3) find symlinks
  so_path=$(find /usr -name 'libcudnn.so*' -type l 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 4) dpkg
  v=$(dpkg-query -W -f='${Version}\n' libcudnn8 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' 'libcudnn*' 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return

  echo "N/A"
}

# ---------------------------------------------------------------------------
# Detection: cuBLAS -- direct library check first
# ---------------------------------------------------------------------------
detect_cublas() {
  local so_path v

  # 1) ldconfig
  so_path=$(ldconfig -p 2>/dev/null | grep 'libcublas.so ' | awk '{print $NF}' | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" 2>/dev/null | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -z "$v" ]] && v=$(basename "$so_path" | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 2) find files
  so_path=$(find /usr -name 'libcublas.so*' -type f 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(basename "$so_path" | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 3) find symlinks
  so_path=$(find /usr -name 'libcublas.so*' -type l 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 4) dpkg
  v=$(dpkg-query -W -f='${Version}\n' libcublas12 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' 'libcublas*' 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return

  echo "N/A"
}

# ---------------------------------------------------------------------------
# Detection: TensorRT -- library and package checks
# ---------------------------------------------------------------------------
detect_tensorrt() {
  local v so_path

  # 1) dpkg - python3-tensorrt or tensorrt packages
  v=$(dpkg-query -W -f='${Version}\n' python3-tensorrt 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' tensorrt 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' 'libnvinfer*' 2>/dev/null | head -1 | sed 's/:.*//')
  [[ -n "$v" ]] && echo "$v" && return

  # 2) library file version
  so_path=$(find /usr -name 'libnvinfer.so*' -type f 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(basename "$so_path" | grep -oP '(?<=libnvinfer\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 3) Python module import
  v=$(python3 -c "import tensorrt; print(tensorrt.__version__)" 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return

  # 4) trt command
  v=$(trt --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')
  [[ -n "$v" ]] && echo "$v" && return

  echo "N/A"
}

# ---------------------------------------------------------------------------
# Detection: cuda-python -- Python package check
# ---------------------------------------------------------------------------
detect_cuda_python() {
  local v

  # 1) Python module import (cuda-python package)
  v=$(python3 -c "import cuda; print(cuda.__version__)" 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return

  # 2) pip show
  v=$(python3 -m pip show cuda-python 2>/dev/null | grep '^Version:' | awk '{print $2}')
  [[ -n "$v" ]] && echo "$v" && return

  # 3) dpkg - cuda-python-* packages
  v=$(dpkg-query -W -f='${Version}\n' 'cuda-python*' 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return

  echo "N/A"
}

# ---------------------------------------------------------------------------
# Format table
# ---------------------------------------------------------------------------
print_row() {
  local label="$1" ctn="$2" nat="$3"
  local match="NO"
  if [[ "$ctn" == "$nat" && "$ctn" != "N/A" ]]; then
    match="YES"
  elif [[ "$ctn" == "N/A" || "$nat" == "N/A" ]]; then
    match="---"
  fi
  printf '  %-17s │ %-23s │ %-24s │ %s\n' "$label" "$ctn" "$nat" "$match"
}

print_divider() {
  printf '  %-17s-+-%-23s-+-%-24s-+-%s\n' \
    "------------------" "------------------------" "-------------------------" "--------"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "========================================================================="
echo " Jetson CUDA Status Check"
echo " Image: ${CONTAINER_IMAGE}"
echo " Hostname: $(hostname)"
echo "========================================================================="
echo ""

# -- Native detection --
echo ">>> Querying native versions..."
nat_toolkit=$(detect_cuda_toolkit)
nat_runtime=$(detect_cuda_runtime)
nat_python=$(detect_python)
nat_cudnn=$(detect_cudnn)
nat_cublas=$(detect_cublas)
nat_tensorrt=$(detect_tensorrt)
nat_cuda_python=$(detect_cuda_python)

# -- Container detection via temp script + docker mount --
echo ">>> Querying container versions (this may take a moment to pull image)..."

PROBE_FILE=$(mktemp /tmp/cuda-probe-XXXXXX.sh)
cat > "$PROBE_FILE" << 'PROBE_SCRIPT'
#!/usr/bin/env bash
set -u

detect_cuda_toolkit() {
  local v
  v=$(python3 -c "
import json,sys
try:
  d=json.load(open('/usr/local/cuda/version.json'))
  print(d.get('cuda',{}).get('version',''))
except: sys.exit(1)
" 2>/dev/null)
  [[ -n "$v" ]] && echo "${v%.*}" && return
  v=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')
  [[ -n "$v" ]] && echo "$v" && return
  v=$(sed -n 's/.*CUDA Version \([0-9]*\.[0-9]*\).*/\1/p' /usr/local/cuda/version.txt 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(readlink -f /usr/local/cuda 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | tail -1)
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

detect_cuda_runtime() {
  local v
  v=$(python3 -c "
import json,sys
try:
  d=json.load(open('/usr/local/cuda/version.json'))
  print(d.get('cuda_cudart',{}).get('version',''))
except: sys.exit(1)
" 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(nvcc --version 2>/dev/null | sed -n 's/.*V\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
  [[ -n "$v" ]] && echo "$v" && return
  v=$(sed -n 's/.*CUDA Version \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' /usr/local/cuda/version.txt 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

detect_python() {
  local v
  v=$(python3 --version 2>/dev/null | awk '{print $2}')
  [[ -n "$v" ]] && echo "$v" && return
  v=$(python --version 2>/dev/null | awk '{print $2}')
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

detect_cudnn() {
  local so_path v
  so_path=$(ldconfig -p 2>/dev/null | grep 'libcudnn.so ' | awk '{print $NF}' | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" 2>/dev/null | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -z "$v" ]] && v=$(basename "$so_path" | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi
  so_path=$(find /usr -name 'libcudnn.so*' -type f 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(basename "$so_path" | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi
  so_path=$(find /usr -name 'libcudnn.so*' -type l 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" | grep -oP '(?<=libcudnn\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi
  v=$(dpkg-query -W -f='${Version}\n' libcudnn8 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' 'libcudnn*' 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

detect_cublas() {
  local so_path v
  so_path=$(ldconfig -p 2>/dev/null | grep 'libcublas.so ' | awk '{print $NF}' | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" 2>/dev/null | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -z "$v" ]] && v=$(basename "$so_path" | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi
  so_path=$(find /usr -name 'libcublas.so*' -type f 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(basename "$so_path" | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi
  so_path=$(find /usr -name 'libcublas.so*' -type l 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(readlink "$so_path" | grep -oP '(?<=libcublas\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi
  v=$(dpkg-query -W -f='${Version}\n' libcublas12 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' 'libcublas*' 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  echo "N/A"
}

detect_tensorrt() {
  local v so_path

  # 1) dpkg - python3-tensorrt or tensorrt packages
  v=$(dpkg-query -W -f='${Version}\n' python3-tensorrt 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' tensorrt 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return
  v=$(dpkg-query -W -f='${Version}\n' 'libnvinfer*' 2>/dev/null | head -1 | sed 's/:.*//')
  [[ -n "$v" ]] && echo "$v" && return

  # 2) library file version
  so_path=$(find /usr -name 'libnvinfer.so*' -type f 2>/dev/null | head -1)
  if [[ -n "$so_path" ]]; then
    v=$(basename "$so_path" | grep -oP '(?<=libnvinfer\.so\.)[0-9]+(\.[0-9]+)*')
    [[ -n "$v" ]] && echo "$v" && return
  fi

  # 3) Python module import
  v=$(python3 -c "import tensorrt; print(tensorrt.__version__)" 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return

  # 4) trt command
  v=$(trt --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')
  [[ -n "$v" ]] && echo "$v" && return

  echo "N/A"
}

detect_cuda_python() {
  local v

  # 1) Python module import (cuda-python package)
  v=$(python3 -c "import cuda; print(cuda.__version__)" 2>/dev/null)
  [[ -n "$v" ]] && echo "$v" && return

  # 2) pip show
  v=$(python3 -m pip show cuda-python 2>/dev/null | grep '^Version:' | awk '{print $2}')
  [[ -n "$v" ]] && echo "$v" && return

  # 3) dpkg - cuda-python-* packages
  v=$(dpkg-query -W -f='${Version}\n' 'cuda-python*' 2>/dev/null | head -1)
  [[ -n "$v" ]] && echo "$v" && return

  echo "N/A"
}

printf 'TK:%s|RT:%s|PY:%s|BL:%s|DN:%s|TR:%s|CP:%s\n' \
  "$(detect_cuda_toolkit)" "$(detect_cuda_runtime)" "$(detect_python)" \
  "$(detect_cublas)" "$(detect_cudnn)" "$(detect_tensorrt)" "$(detect_cuda_python)"
PROBE_SCRIPT
chmod +x "$PROBE_FILE"

container_raw=$(docker run --rm --network none \
  -v "${PROBE_FILE}:/tmp/probe.sh:ro" \
  "$CONTAINER_IMAGE" \
  bash /tmp/probe.sh 2>&1) || true

rm -f "$PROBE_FILE"

if [[ -z "$container_raw" ]]; then
  echo "WARNING: container probe produced no output (docker run may have failed)" >&2
  echo "  Image: ${CONTAINER_IMAGE}" >&2
fi

# -- Parse container fields --
ctn_toolkit=$(echo "$container_raw" | grep -oP '(?<=TK:)[^|]+' | head -1 || echo "N/A")
ctn_runtime=$(echo "$container_raw" | grep -oP '(?<=RT:)[^|]+' | head -1 || echo "N/A")
ctn_python=$(echo "$container_raw" | grep -oP '(?<=PY:)[^|]+' | head -1 || echo "N/A")
ctn_cublas=$(echo "$container_raw" | grep -oP '(?<=BL:)[^|]+' | head -1 || echo "N/A")
ctn_cudnn=$(echo "$container_raw" | grep -oP '(?<=DN:)[^|]+' | head -1 || echo "N/A")
ctn_tensorrt=$(echo "$container_raw" | grep -oP '(?<=TR:)[^|]+' | head -1 || echo "N/A")
ctn_cuda_python=$(echo "$container_raw" | grep -oP '(?<=CP:)[^|]+' | head -1 || echo "N/A")

# -- Print comparison table --
echo ""

printf '  %-17s │ %-23s │ %-24s │ %s\n' \
  "Component" "Container" "Native Device" "Match"
print_divider

print_row "CUDA Toolkit"    "$ctn_toolkit"     "$nat_toolkit"
print_row "CUDA Runtime"    "$ctn_runtime"     "$nat_runtime"
print_row "Python"          "$ctn_python"      "$nat_python"
print_row "cuBLAS"          "$ctn_cublas"      "$nat_cublas"
print_row "cuDNN"           "$ctn_cudnn"       "$nat_cudnn"
print_row "TensorRT"        "$ctn_tensorrt"    "$nat_tensorrt"
print_row "cuda-python"     "$ctn_cuda_python" "$nat_cuda_python"

echo ""
echo "========================================================================="
echo " Report complete"
echo "========================================================================="

exit 0
