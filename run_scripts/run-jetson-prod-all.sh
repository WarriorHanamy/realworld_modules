#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# run-jetson-production.sh — Full Jetson production stack
#
# Linker:   PX4 connector + FAST-LIO2 + Livox (independent containers)
# BHT:      neural gate + inference (single-container, docker exec pattern)
#
# Usage:
#   ./run-jetson-production.sh [OPTIONS]
#
# Options:
#   --skip-linker       Skip PX4 connector + LIO pipeline
#   --skip-infer        Skip neural services (BHT)
#   -h, --help          Show help
# =============================================================================

if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux is not installed. Install with: sudo apt install tmux"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_UTILS="${SCRIPT_DIR}/tmux_utils.sh"

if [[ ! -f "$TMUX_UTILS" ]]; then
  echo "ERROR: tmux_utils.sh not found at: $TMUX_UTILS"
  exit 1
fi

# shellcheck source=/dev/null
source "$TMUX_UTILS"

# --- Global Configuration ---------------------------------------------------
SESSION="jetson-prod"
PX4_IMAGE="vtol/px4-connector-jetson:latest"
LIO_IMAGE="vtol/lio-jetson:latest"
BHT_IMAGE="vtol/bht-jetson:latest"
BHT_CONTAINER="bht-production"
ROS2_WS_DIR="/home/ros/ros2_ws"

INTERFACE="enP8p1s0"
LIVOX_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/livox_mid360.json"
FAST_LIO_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/fastlio_mid360.yaml"
LIVOX_CONFIG_CONTAINER="${ROS2_WS_DIR}/install/livox_ros_driver2/share/livox_ros_driver2/config/MID360_config.json"
FAST_LIO_CONFIG_CONTAINER="${ROS2_WS_DIR}/install/fast_lio/share/fast_lio/config/mid360.yaml"

POLICIES_DIR="/home/nv/server/policies"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-local.xml"
RUNTIME_CONFIG_DIR="/tmp/linker-config"
PX4_AGENT_REFS="${SCRIPT_DIR}/config/uxrce-agent-local.refs"

FAST_LIO_IMU_TOPIC="/px4/imu"
FAST_LIO_EXTRINSIC_T="[ -0.03, 0.0, 0.09 ]"
FAST_LIO_EXTRINSIC_R="[0.000000, 0.965926, 0.258819, -1.000000, 0.000000, 0.000000, 0.000000, -0.258819, 0.965926]"

# --- Feature Flags ----------------------------------------------------------
START_LINKER=true
START_INFER=true

# --- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Production startup for complete Jetson stack:"
      echo "  - PX4 connector + LIO (sensor fusion)"
      echo "  - BHT neural services (single-container docker exec)"
      echo ""
      echo "Options:"
      echo "  --skip-linker      Skip PX4 connector + LIO"
      echo "  --skip-infer       Skip neural services"
      echo "  -h, --help         Show this help"
      exit 0
      ;;
    --skip-linker)
      START_LINKER=false
      shift
      ;;
    --skip-infer)
      START_INFER=false
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# --- Validation: Linker -----------------------------------------------------
if [[ "$START_LINKER" == "true" ]]; then
  echo "Validating LIO pipeline..."

  if [[ ! -f "$PX4_AGENT_REFS" ]]; then
    echo "ERROR: XRCE agent refs not found: $PX4_AGENT_REFS"
    exit 1
  fi

  if ! docker image inspect "$PX4_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Image $PX4_IMAGE not found."
    exit 1
  fi

  if ! docker image inspect "$LIO_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Image $LIO_IMAGE not found."
    exit 1
  fi

  echo "  ✓ PX4 connector image found"
  echo "  ✓ LIO image found"
fi

# --- Validation: BHT --------------------------------------------------------
if [[ "$START_INFER" == "true" ]]; then
  echo "Validating BHT services..."

  if ! docker image inspect "$BHT_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Image $BHT_IMAGE not found."
    exit 1
  fi

  if [[ ! -f "${FASTDDS_CONFIG}" ]]; then
    echo "ERROR: FastDDS config not found: ${FASTDDS_CONFIG}"
    exit 1
  fi

  echo "  ✓ BHT image found"
  echo "  ✓ FastDDS config found"
fi

# --- Cleanup existing containers -------------------------------------------
echo ""
echo "Cleaning up existing containers..."
if [[ "$START_LINKER" == "true" ]]; then
  docker ps -a --filter "ancestor=${PX4_IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true
  docker ps -a --filter "ancestor=${LIO_IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true
fi

if [[ "$START_INFER" == "true" ]]; then
  docker rm -f "${BHT_CONTAINER}" 2>/dev/null || true
fi

# --- Linker: Network discovery & config generation -------------------------
if [[ "$START_LINKER" == "true" ]]; then
  echo ""
  echo "Preparing LIO pipeline..."

  mkdir -p "$RUNTIME_CONFIG_DIR"

  echo "  Discovering network configuration on $INTERFACE..."
  HOST_IP=$(ip addr show dev "$INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
  LIDAR_IP=$(ip neigh show dev "$INTERFACE" 2>/dev/null | grep -v "INCOMPLETE" | grep -v "FAILED" | awk '{print $1}' | grep -v "\.255$" | head -1)

  if [[ -z "$HOST_IP" || -z "$LIDAR_IP" ]]; then
    echo "ERROR: Could not discover IPs on $INTERFACE"
    echo "  HOST_IP=${HOST_IP:-<empty>}"
    echo "  LIDAR_IP=${LIDAR_IP:-<empty>}"
    exit 1
  fi
  echo "  LiDAR IP: $LIDAR_IP  Host IP: $HOST_IP"

  sed -e "s|\\\$HOST_IP|${HOST_IP}|g" \
      -e "s|\\\$LIDAR_IP|${LIDAR_IP}|g" \
      "$LIVOX_CONFIG_TEMPLATE" > "$RUNTIME_CONFIG_DIR/livox_mid360.json"

  FAST_LIO_IMU_TOPIC="$FAST_LIO_IMU_TOPIC" \
  FAST_LIO_EXTRINSIC_T="$FAST_LIO_EXTRINSIC_T" \
  FAST_LIO_EXTRINSIC_R="$FAST_LIO_EXTRINSIC_R" \
  python3 - "$FAST_LIO_CONFIG_TEMPLATE" "$RUNTIME_CONFIG_DIR/fastlio_mid360.yaml" <<'PY'
from pathlib import Path
import os
import sys

template = Path(sys.argv[1]).read_text()
rendered = (
    template
    .replace("$FAST_LIO_IMU_TOPIC", os.environ["FAST_LIO_IMU_TOPIC"])
    .replace("$FAST_LIO_EXTRINSIC_T", os.environ["FAST_LIO_EXTRINSIC_T"])
    .replace("$FAST_LIO_EXTRINSIC_R", os.environ["FAST_LIO_EXTRINSIC_R"])
)
Path(sys.argv[2]).write_text(rendered)
PY

  echo "  Generated runtime configs"
fi

# --- BHT: Start background container ---------------------------------------
if [[ "$START_INFER" == "true" ]]; then
  echo ""
  echo "Starting BHT background container..."

  POLICIES_VOLUME=()
  if [[ -d "${POLICIES_DIR}" ]]; then
    POLICIES_VOLUME=(-v "${POLICIES_DIR}:/home/ros/policies:ro")
    echo "  Policies mounted from ${POLICIES_DIR}"
  fi

  docker run -d \
    --name "${BHT_CONTAINER}" \
    --net=host \
    --ipc=host \
    --privileged \
    -e ROS_DOMAIN_ID=30 \
    -e ROS_LOCALHOST_ONLY=1 \
    -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
    -e FASTDDS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
    -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro" \
    "${POLICIES_VOLUME[@]}" \
    "${BHT_IMAGE}" \
    tail -f /dev/null

  echo "  BHT container ${BHT_CONTAINER} running."
fi

# --- Start tmux session ---------------------------------------------------
echo ""
fn_tmux_session_safe_start "$SESSION"

# --- Window 1: PX4 Connector ------------------------------------------------
if [[ "$START_LINKER" == "true" ]]; then
  echo "Starting PX4 connector..."
  fn_tmux_window_rename "$SESSION" "main" "px4-connector"

  px4_connector_cmd="docker run --rm --name px4-connector-jetson --net=host --ipc=host --privileged -e ROS_DOMAIN_ID=30 -e ROS_LOCALHOST_ONLY=1 --cpuset-cpus=6,7 -e XRCE_DOMAIN_ID_OVERRIDE=30 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e MICRO_XRCE_REFS_FILE=/etc/uxrce/agent.refs -e MICRO_XRCE_DEVICE=${MICRO_XRCE_DEVICE:-/dev/ttyTHS1} -e MICRO_XRCE_BAUDRATE=${MICRO_XRCE_BAUDRATE:-921600} -e OUTPUT_MODE=${OUTPUT_MODE:-topic} -e IMU_OUTPUT_TOPIC=${IMU_OUTPUT_TOPIC:-/px4/imu} -v ${PX4_AGENT_REFS}:/etc/uxrce/agent.refs:ro -v ${SCRIPT_DIR}/config/px4-entrypoint.sh:/entrypoint.sh:ro --entrypoint bash ${PX4_IMAGE} /entrypoint.sh"
  fn_tmux_pane_run "$SESSION" "px4-connector" "" "$px4_connector_cmd"

  # --- Window 2: LIO ---------------------------------------------------
  echo "Starting LIO container..."
  fn_tmux_window_new "$SESSION" "lio"

  lio_cmd="docker run --rm --name lio-jetson --net=host --ipc=host --cpuset-cpus=2,3,4,5 -e ROS_DOMAIN_ID=30 -e ROS_LOCALHOST_ONLY=1 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -e FASTDDS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro -v ${RUNTIME_CONFIG_DIR}/livox_mid360.json:${LIVOX_CONFIG_CONTAINER}:ro -v ${RUNTIME_CONFIG_DIR}/fastlio_mid360.yaml:${FAST_LIO_CONFIG_CONTAINER}:ro -v ${SCRIPT_DIR}/config/lio-entrypoint.sh:/entrypoint.sh:ro --entrypoint '' ${LIO_IMAGE} bash /entrypoint.sh"
  fn_tmux_pane_run "$SESSION" "lio" "" "$lio_cmd"
fi

# --- Window 3+: BHT Neural Services (single-container docker exec) ---------
if [[ "$START_INFER" == "true" ]]; then
  echo "Starting BHT neural services..."

  fn_tmux_window_new "$SESSION" "infer"

  infer_cmd="docker exec -it ${BHT_CONTAINER} bash -lc 'set +u; source /opt/ros/humble/setup.bash && source ${ROS2_WS_DIR}/install/setup.bash; set -u; ros2 launch neural_inference task_track.launch.py'"
  fn_tmux_pane_run "$SESSION" "infer" "" "$infer_cmd"

  fn_tmux_window_new "$SESSION" "shell"

  shell_cmd="docker exec -it ${BHT_CONTAINER} bash -lc 'set +u; source /opt/ros/humble/setup.bash && source ${ROS2_WS_DIR}/install/setup.bash; set -u; exec bash'"
  fn_tmux_pane_run "$SESSION" "shell" "" "$shell_cmd"
fi

# --- Window N: Monitor ----------------------------------------------------
echo "Creating monitor window..."
fn_tmux_window_new "$SESSION" "monitor"

if [[ "$START_LINKER" == "true" ]] && [[ "$START_INFER" == "true" ]]; then
  monitor_text=$(cat <<MONITOR_TEXT
Jetson Production Stack
========================

Linker:
  PX4 Image: ${PX4_IMAGE}
  LIO Image: ${LIO_IMAGE}

BHT:
  Image:     ${BHT_IMAGE}
  Container: ${BHT_CONTAINER} (shared by infer + shell)

Session: ${SESSION}
FastDDS:  ${FASTDDS_CONFIG}

Data Flow:
  PX4 FMU → PX4 connector → /px4/imu
  Livox LiDAR → livox_ros_driver2 → /livox/lidar
  /px4/imu + /livox/lidar → FAST-LIO → /Odometry
  /Odometry → PX4 connector → /fmu/in/vehicle_visual_odometry
  /Odometry + sensors → BHT task_track.launch.py → /neural/control
  /neural/control → PX4 offboard control

Windows:
  1. px4-connector - PX4 connector output
  2. lio           - LiDAR + FAST-LIO2 output
  3. infer         - BHT task_track.launch.py (gate + inference)
  4. shell         - Interactive BHT shell (docker exec)
  5. monitor       - This screen

Topics to watch:
  ros2 topic echo /neural/reference_state
  ros2 topic echo /neural/reset_track
  ros2 topic echo /fmu/in/vehicle_acc_rates_setpoint
MONITOR_TEXT
)
elif [[ "$START_LINKER" == "true" ]]; then
  monitor_text="Jetson Production Stack: Linker only (--skip-infer)"
elif [[ "$START_INFER" == "true" ]]; then
  monitor_text="Jetson Production Stack: BHT only (--skip-linker)"
else
  monitor_text="Jetson Production Stack: No services enabled"
fi

fn_tmux_pane_run "$SESSION" "monitor" "" "cat <<'EOF'
${monitor_text}
EOF
sleep infinity"

# --- Summary & Attach -------------------------------------------------------
echo ""
echo "========================================"
echo " Jetson Production Stack Started"
echo "========================================"
echo ""
echo "Session: ${SESSION}"
echo ""
echo "Features enabled:"
if [[ "$START_LINKER" == "true" ]]; then
  echo "  ✓ LIO pipeline (PX4 + LiDAR + FAST-LIO2)"
fi
if [[ "$START_INFER" == "true" ]]; then
  echo "  ✓ BHT neural (single-container: ${BHT_CONTAINER})"
fi
echo ""
echo "Attach to session:"
echo "  tmux attach -t ${SESSION}"
echo ""

fn_tmux_attach "$SESSION"
