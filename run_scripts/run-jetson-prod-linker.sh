#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# run-prod-jetson-linker.sh — Production startup for PX4 connector + LIO
#
# Starts:
#   1. PX4 connector (publishes /px4/imu)
#   2. LIO container:
#      - livox_ros_driver2 (publishes /livox/lidar)
#      - FAST-LIO (starts when both /px4/imu and /livox/lidar exist)
#
# Data flow:
#   PX4 FMU → PX4 connector → /px4/imu
#   Livox LiDAR → livox_ros_driver2 → /livox/lidar
#   /px4/imu + /livox/lidar → FAST-LIO → /Odometry
#   /Odometry → PX4 connector → /fmu/in/vehicle_visual_odometry
# ==============================================================================

# Ensure tmux is installed
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

# --- Configuration -----------------------------------------------------------
SESSION="jetson-prod-linker"
PX4_IMAGE="vtol/px4-connector-jetson:latest"
LIO_IMAGE="vtol/lio-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"
FASTDDS_PX4_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml" #patch now
INTERFACE="enP8p1s0"
LIVOX_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/livox_mid360.json"
FAST_LIO_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/fastlio_mid360.yaml"
LIVOX_CONFIG_CONTAINER="/root/ros2_ws/install/livox_ros_driver2/share/livox_ros_driver2/config/MID360_config.json"
FAST_LIO_CONFIG_CONTAINER="/root/ros2_ws/install/fast_lio/share/fast_lio/config/mid360.yaml"

# FAST-LIO parameters
FAST_LIO_IMU_TOPIC="/px4/imu"
FAST_LIO_EXTRINSIC_T="[ -0.03, 0.0, 0.09 ]"
#FAST_LIO_EXTRINSIC_T="[ -0.0, 0.0, 0.0 ]"
FAST_LIO_EXTRINSIC_R="[0.000000, 0.965926, 0.258819, -1.000000, 0.000000, 0.000000, 0.000000, -0.258819, 0.965926]"

# FAST_LIO_EXTRINSIC_R="[ 0., 0.9659258263, 0.2588190451,
#                         1., 0., 0.,
#                         0., 0.2588190451, 0.9659258263]"


# FAST_LIO_EXTRINSIC_R="[ 1., 0.0, 0.0,
#                         0., 1., 0.,
#                         0., 0., 1.0]"
#
# --- Argument parsing --------------------------------------------------------
BAG_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $0 [--bag <bagfile>]"
      echo ""
      echo "Production startup for PX4 connector + LIO pipeline"
      echo ""
      echo "Options:"
      echo "  --bag <file>   Play bag file instead of live sensor"
      echo "  -h, --help     Show this help"
      exit 0
      ;;
    --bag)
      BAG_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# --- Validation --------------------------------------------------------------
if [[ ! -f "$FASTDDS_CONFIG" ]]; then
  echo "ERROR: FastDDS config not found: $FASTDDS_CONFIG"
  exit 1
fi

if ! docker image inspect "$PX4_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $PX4_IMAGE not found. Build with: make docker-build-px4-connector-jetson"
  exit 1
fi

if ! docker image inspect "$LIO_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $LIO_IMAGE not found. Build with: make docker-build-lio-jetson"
  exit 1
fi

# --- Cleanup existing containers ---------------------------------------------
echo "Cleaning up existing containers..."
docker ps -a --filter "ancestor=${PX4_IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${PX4_IMAGE}" -q | xargs -r docker rm 2>/dev/null || true
docker ps -a --filter "ancestor=${LIO_IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${LIO_IMAGE}" -q | xargs -r docker rm 2>/dev/null || true

# --- Discover LiDAR IP ------------------------------------------------------
HOST_IP=""
LIDAR_IP=""

if [[ -z "$BAG_FILE" ]]; then
  echo "Discovering network configuration on $INTERFACE..."
  HOST_IP=$(ip addr show dev "$INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
  LIDAR_IP=$(ip neigh show dev "$INTERFACE" 2>/dev/null | grep -v "INCOMPLETE" | grep -v "FAILED" | awk '{print $1}' | grep -v "\.255$" | head -1)

  if [[ -z "$HOST_IP" || -z "$LIDAR_IP" ]]; then
    echo "ERROR: Could not discover IPs on $INTERFACE"
    echo "  HOST_IP=${HOST_IP:-<empty>}"
    echo "  LIDAR_IP=${LIDAR_IP:-<empty>}"
    exit 1
  fi
  echo "LiDAR IP: $LIDAR_IP  Host IP: $HOST_IP"
fi

# --- Generate runtime configs ------------------------------------------------
RUNTIME_CONFIG_DIR="/tmp/linker-config"
mkdir -p "$RUNTIME_CONFIG_DIR"

# Livox config
if [[ -n "$LIDAR_IP" && -n "$HOST_IP" ]]; then
  sed -e "s|\\\$HOST_IP|${HOST_IP}|g" \
      -e "s|\\\$LIDAR_IP|${LIDAR_IP}|g" \
      "$LIVOX_CONFIG_TEMPLATE" > "$RUNTIME_CONFIG_DIR/livox_mid360.json"
fi

# FAST-LIO config
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

echo "Generated configs in $RUNTIME_CONFIG_DIR"

# --- Start tmux session ------------------------------------------------------
fn_tmux_session_safe_start "$SESSION"

# --- Window 1: PX4 Connector ------------------------------------------------
echo "Starting PX4 connector..."
fn_tmux_window_rename "$SESSION" "main" "px4-connector"

px4_connector_cmd="docker run --rm --name px4-connector-jetson --net=host --ipc=host --privileged -e ROS_DOMAIN_ID=30 --cpuset-cpus=6,7 -e XRCE_DOMAIN_ID_OVERRIDE=30 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e MICRO_XRCE_DEVICE=${MICRO_XRCE_DEVICE:-/dev/ttyTHS1} -e MICRO_XRCE_BAUDRATE=${MICRO_XRCE_BAUDRATE:-921600} -e OUTPUT_MODE=${OUTPUT_MODE:-topic} -e IMU_OUTPUT_TOPIC=${IMU_OUTPUT_TOPIC:-/px4/imu} -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -v ${FASTDDS_PX4_CONFIG}:/etc/fastdds/fastdds.xml:ro -v ${SCRIPT_DIR}/config/px4-entrypoint.sh:/entrypoint.sh:ro --entrypoint bash ${PX4_IMAGE} /entrypoint.sh"
fn_tmux_pane_run "$SESSION" "px4-connector" "" "$px4_connector_cmd"

# --- Window 2: LIO (Livox + FAST-LIO) ---------------------------------------
echo "Starting LIO container..."
fn_tmux_window_new "$SESSION" "lio"

lio_cmd="docker run --rm --name lio-jetson --net=host --ipc=host --cpuset-cpus=2,3,4,5 -e ROS_DOMAIN_ID=30 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -v ${RUNTIME_CONFIG_DIR}/livox_mid360.json:${LIVOX_CONFIG_CONTAINER}:ro -v ${RUNTIME_CONFIG_DIR}/fastlio_mid360.yaml:${FAST_LIO_CONFIG_CONTAINER}:ro -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro -v ${SCRIPT_DIR}/config/lio-entrypoint.sh:/entrypoint.sh:ro --entrypoint '' ${LIO_IMAGE} bash /entrypoint.sh"
fn_tmux_pane_run "$SESSION" "lio" "" "$lio_cmd"

# --- Window 3: Monitor -------------------------------------------------------
echo "Creating monitor window..."
monitor_script=$(cat <<MONITOR_EOF
set +u
source /opt/ros/humble/setup.bash
set -u
export ROS_DOMAIN_ID=30
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export FASTRTPS_DEFAULT_PROFILES_FILE=$(printf '%q' "$FASTDDS_CONFIG")

echo "=== Jetson Linker Monitor ==="
echo ""
echo "Session: jetson-prod-linker"
echo ""
echo "Data flow:"
echo "  PX4 FMU → PX4 connector → /px4/imu"
echo "  Livox LiDAR → livox_ros_driver2 → /livox/lidar"
echo "  /px4/imu + /livox/lidar → FAST-LIO → /Odometry"
echo "  /Odometry → PX4 connector → /fmu/in/vehicle_visual_odometry"
echo ""
echo "Checking topics..."
echo ""

while true; do
  echo "--- \$(date '+%H:%M:%S') ---"

  # Check /px4/imu
  if ros2 topic list 2>/dev/null | grep -q "/px4/imu"; then
    echo "[✓] /px4/imu available"
  else
    echo "[✗] /px4/imu not available"
  fi

  # Check /livox/lidar
  if ros2 topic list 2>/dev/null | grep -q "/livox/lidar"; then
    echo "[✓] /livox/lidar available"
  else
    echo "[✗] /livox/lidar not available"
  fi

  # Check /Odometry
  if ros2 topic list 2>/dev/null | grep -q "/Odometry"; then
    echo "[✓] /Odometry available"
  else
    echo "[✗] /Odometry not available"
  fi

  # Check /fmu/in/vehicle_visual_odometry
  if ros2 topic list 2>/dev/null | grep -q "/fmu/in/vehicle_visual_odometry"; then
    echo "[✓] /fmu/in/vehicle_visual_odometry available"
  else
    echo "[✗] /fmu/in/vehicle_visual_odometry not available"
  fi

  echo ""
  sleep 2
done
MONITOR_EOF
)
fn_tmux_window_create_and_run_bash "$SESSION" "monitor" "$monitor_script"

# --- Window 4: Shell access --------------------------------------------------
echo "Creating shell window..."
shell_script=$(cat <<'SHELL_EOF'
echo "=== Container Shell Access ==="
echo ""
echo "Waiting for containers to start..."
sleep 10

echo "Available containers:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
echo ""
echo "To exec into a container:"
echo "  docker exec -it <container_name> bash"
echo ""
echo "Examples:"
echo "  docker exec -it px4-connector-jetson bash"
echo "  docker exec -it lio-jetson bash"
echo ""
echo "Attaching to PX4 connector now..."
docker exec -it px4-connector-jetson bash -c "source /opt/ros/humble/setup.bash && source /root/px4_connector_ws/install/setup.bash && exec bash" || true
echo ""
echo "To re-attach: tmux attach -t jetson-prod-linker"
SHELL_EOF
)
fn_tmux_window_create_and_run_bash "$SESSION" "shell" "$shell_script"

fn_tmux_window_select "$SESSION" "monitor"

# --- Select monitor window ---------------------------------------------------
fn_tmux_window_select "$SESSION" "monitor"

# --- Wait for containers to be ready -----------------------------------------
echo "Waiting for containers to start..."
sleep 3


# --- Return to monitor window ------------------------------------------------
fn_tmux_window_select "$SESSION" "monitor"

# --- Output summary ----------------------------------------------------------
echo ""
echo "========================================"
echo " Jetson Linker Started"
echo "========================================"
echo ""
echo "Session: $SESSION"
echo ""
echo "Windows:"
echo "  1. px4-connector  - PX4 connector (publishes /px4/imu)"
echo "  2. lio            - LIO container (livox + FAST-LIO)"
echo "  3. monitor        - Topic status monitor"
echo "  4. shell          - Container shell access"
echo ""
echo "Attach: tmux attach-session -t $SESSION"
echo ""


tmux attach-session -t $SESSION
