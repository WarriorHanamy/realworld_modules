#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# run-jetson-prod-neural-infer.sh — Production neural inference on Jetson
#
# This script runs fully on the Jetson device.
# It starts a tmux session with:
#   1. infer - neural inference container
#   2. shell - interactive shell in the same image
#
# Prerequisite:
#   - Policies must already exist at /home/nv/server/policies
# =============================================================================

if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux is not installed. Install with: sudo apt install tmux"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_UTILS="${SCRIPT_DIR}/tmux_utils.sh"

if [[ ! -f "${TMUX_UTILS}" ]]; then
  echo "ERROR: tmux_utils.sh not found at: ${TMUX_UTILS}"
  exit 1
fi

# shellcheck source=/dev/null
source "${TMUX_UTILS}"

SESSION="jetson-prod-neural-infer"
IMAGE="vtol/bht-jetson:latest"
INFER_CONTAINER_NAME="neural-infer-jetson"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"
JETSON_POLICIES_DIR="/home/nv/server/policies"
BHT_SRC_DIR="/home/nv/realworld_modules/vtol_behavior_manager/src"
PYDEPS_DIR="/home/nv/.cache/vtol-neural-pydeps"

if [[ ! -f "${FASTDDS_CONFIG}" ]]; then
  echo "ERROR: FastDDS config not found: ${FASTDDS_CONFIG}"
  exit 1
fi

if [[ ! -d "${JETSON_POLICIES_DIR}" ]]; then
  echo "ERROR: Policies directory not found: ${JETSON_POLICIES_DIR}"
  echo "Run the host-side sync separately before starting inference."
  exit 1
fi

if [[ ! -d "${BHT_SRC_DIR}" ]]; then
  echo "ERROR: Source directory not found: ${BHT_SRC_DIR}"
  exit 1
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: Image ${IMAGE} not found. Build/load it before running this script."
  exit 1
fi

mkdir -p "${PYDEPS_DIR}"

echo "Cleaning up existing inference container..."
docker ps -a --filter "name=${INFER_CONTAINER_NAME}" -q | xargs -r docker rm -f 2>/dev/null || true

echo "Starting tmux session ${SESSION}..."
fn_tmux_session_safe_start "${SESSION}"
fn_tmux_window_rename "${SESSION}" "main" "infer"

infer_cmd="docker run --rm --name ${INFER_CONTAINER_NAME} --user root --net=host --ipc=host --privileged -e ROS_DOMAIN_ID=30 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro -v ${JETSON_POLICIES_DIR}:/home/ros/policies:ro -v ${BHT_SRC_DIR}:/root/ros2_ws/src:ro -v ${PYDEPS_DIR}:/opt/neural_pydeps ${IMAGE} bash -lc \"set +u; source /opt/ros/humble/setup.bash; if [ -f /root/ros2_ws/install/setup.bash ]; then source /root/ros2_ws/install/setup.bash; fi; set -u; python3 -c 'import sys; sys.path.insert(0, \\\"/opt/neural_pydeps\\\"); sys.path.insert(0, \\\"/root/ros2_ws/src\\\"); import hydra, numpy, onnxruntime, neural_manager.neural_inference.neural_infer' >/dev/null 2>&1 || python3 -m pip install --no-cache-dir --target /opt/neural_pydeps hydra-core onnxruntime; python3 -c 'import runpy, sys; sys.path.insert(0, \\\"/opt/neural_pydeps\\\"); sys.path.insert(0, \\\"/root/ros2_ws/src\\\"); runpy.run_module(\\\"neural_manager.neural_inference.neural_infer\\\", run_name=\\\"__main__\\\")'\""
fn_tmux_pane_run "${SESSION}" "infer" "" "${infer_cmd}"

fn_tmux_window_new "${SESSION}" "shell"
shell_cmd="docker run --rm -it --user root --net=host --ipc=host --privileged -e ROS_DOMAIN_ID=30 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro -v ${JETSON_POLICIES_DIR}:/home/ros/policies:ro -v ${BHT_SRC_DIR}:/root/ros2_ws/src:ro -v ${PYDEPS_DIR}:/opt/neural_pydeps ${IMAGE} bash -lc \"set +u; source /opt/ros/humble/setup.bash; if [ -f /root/ros2_ws/install/setup.bash ]; then source /root/ros2_ws/install/setup.bash; fi; set -u; python3 -c 'import sys; sys.path.insert(0, \\\"/opt/neural_pydeps\\\"); sys.path.insert(0, \\\"/root/ros2_ws/src\\\"); import hydra, numpy, onnxruntime, neural_manager.neural_inference.neural_infer' >/dev/null 2>&1 || python3 -m pip install --no-cache-dir --target /opt/neural_pydeps hydra-core onnxruntime; exec bash\""
fn_tmux_pane_run "${SESSION}" "shell" "" "${shell_cmd}"

fn_tmux_window_select "${SESSION}" "shell"

echo ""
echo "========================================"
echo " Jetson Neural Infer Started"
echo "========================================"
echo ""
echo "Session: ${SESSION}"
echo "Image:   ${IMAGE}"
echo "Policies: ${JETSON_POLICIES_DIR}"
echo "FastDDS:  ${FASTDDS_CONFIG}"
echo ""
echo "Windows:"
echo "  1. infer - neural inference container"
echo "  2. shell - interactive shell container"
echo ""

fn_tmux_attach "${SESSION}"
