#!/usr/bin/env bash
set -eo pipefail

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

SESSION="jetson-debug-linker-integrated"
PX4_IMAGE="vtol/px4-connector-jetson:latest"
LIO_IMAGE="vtol/lio-jetson:latest"
CALIB_IMAGE="vtol/calib-lidar-imu-init-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"
INTERFACE="enP8p1s0"
LIVOX_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/livox_mid360.json"
LIVOX_CONFIG_CONTAINER="/root/catkin_ws/src/livox_ros_driver2/config/MID360_config.json"
FAST_LIO_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/fastlio_mid360.yaml"
FAST_LIO_IMU_TOPIC="/livox/imu"
FAST_LIO_EXTRINSIC_T="[ -0.03, 0.0, 0.09 ]"
FAST_LIO_EXTRINSIC_R="[ 0.0, 0.9681, 0.2504, -1.0, 0.0, 0.0, 0.0, -0.2504, 0.9681 ]"

# Validate config file
if [[ ! -f "$FASTDDS_CONFIG" ]]; then
  echo "ERROR: FastDDS config not found: $FASTDDS_CONFIG"
  exit 1
fi

# Parse arguments
BAG_FILE=""
CALIB_MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $0 [--bag <bagfile>] [--calib-mode <live|bag>]"
      echo "  --bag <file>       Play bag file for calibration"
      echo "  --calib-mode <mode>  'live' for live sensor, 'bag' for bag playback"
      exit 0
      ;;
    --bag) BAG_FILE="$2"; shift 2 ;;
    --calib-mode) CALIB_MODE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Check images
if ! docker image inspect "$PX4_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $PX4_IMAGE not found. Build with: make docker-build-px4-connector-jetson (in linker/)"
  exit 1
fi
if ! docker image inspect "$LIO_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $LIO_IMAGE not found. Build with: make docker-build-lio-jetson (in linker/)"
  exit 1
fi
if ! docker image inspect "$CALIB_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $CALIB_IMAGE not found. Build with: make docker-build-calib-jetson (in linker/)"
  exit 1
fi

# Cleanup existing containers from same images
echo "Cleaning up existing containers from $PX4_IMAGE, $LIO_IMAGE, and $CALIB_IMAGE..."
docker ps -a --filter "ancestor=${PX4_IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${PX4_IMAGE}" -q | xargs -r docker rm 2>/dev/null || true
docker ps -a --filter "ancestor=${LIO_IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${LIO_IMAGE}" -q | xargs -r docker rm 2>/dev/null || true
docker ps -a --filter "ancestor=${CALIB_IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${CALIB_IMAGE}" -q | xargs -r docker rm 2>/dev/null || true

# Generate runtime config files
RUNTIME_CONFIG_DIR="/tmp/linker-integrated-config"
mkdir -p "$RUNTIME_CONFIG_DIR"

# Generate Livox config (for calibration window)
HOST_IP=$(ip addr show dev "$INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
LIDAR_IP=$(ip neigh show dev "$INTERFACE" 2>/dev/null | grep -v "INCOMPLETE" | grep -v "FAILED" | awk '{print $1}' | grep -v "\.255$" | head -1)
if [[ -z "$HOST_IP" || -z "$LIDAR_IP" ]]; then
  echo "WARNING: Could not discover IPs on $INTERFACE, using defaults"
  HOST_IP="${HOST_IP:-192.168.55.100}"
  LIDAR_IP="${LIDAR_IP:-192.168.55.1}"
fi
sed -e "s|\$HOST_IP|${HOST_IP}|g" \
    -e "s|\$LIDAR_IP|${LIDAR_IP}|g" \
    "$LIVOX_CONFIG_TEMPLATE" > "$RUNTIME_CONFIG_DIR/livox_mid360.json"

# Generate Fast LIO config with specified extrinsics
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

# Kill host-side rosmaster so container can bind port 11311
pkill -f rosmaster 2>/dev/null || true
pkill -f roscore 2>/dev/null || true

# Clean up old session and start fresh
fn_tmux_session_safe_start "$SESSION"

# =============================================================================
# Window 1: PX4 Connector (ROS2 → IMU bridge)
# =============================================================================
fn_tmux_window_new "$SESSION" "px4-connector"
px4_cmd="docker run --rm --network host --ipc host --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro \
  -v /tmp:/tmp \
  ${PX4_IMAGE} \
  bash -c 'set +u; source /opt/ros/humble/setup.bash; source /root/px4_connector_ws/install/setup.bash; set -u; ros2 launch imu_bridge sender.launch.py'"
fn_tmux_pane_run "$SESSION" "px4-connector" "" "$px4_cmd"

# =============================================================================
# Window 2: LIO (FastLIO + Livox driver)
# =============================================================================
fn_tmux_window_new "$SESSION" "lio"
lio_cmd="docker run --rm --network host --ipc host --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro \
  -v ${RUNTIME_CONFIG_DIR}/fastlio_mid360.yaml:/root/ros2_ws/install/fast_lio/share/fast_lio/config/fastlio_mid360.yaml:ro \
  -v /tmp:/tmp \
  ${LIO_IMAGE} \
  bash -c 'set -eo pipefail; set +u; \
    source /opt/ros/humble/setup.bash; \
    source /root/ros2_ws/install/setup.bash; \
    set -u; \
    echo \"Starting Livox driver...\"; \
    ros2 launch livox_ros_driver2 msg_MID360_launch.py & \
    DRIVER_PID=\$!; \
    echo \"Waiting for /livox/lidar topic...\"; \
    until ros2 topic list 2>/dev/null | grep -q \"/livox/lidar\"; do \
      sleep 1; \
    done; \
    echo \"/livox/lidar topic is available\"; \
    echo \"Starting Fast LIO...\"; \
    ros2 launch fast_lio mapping.launch.py config_file:=fastlio_mid360.yaml rviz:=false'"
fn_tmux_pane_run "$SESSION" "lio" "" "$lio_cmd"

# =============================================================================
# Window 3: Calibration (bag playback or live sensor)
# =============================================================================
fn_tmux_window_new "$SESSION" "calibration"
if [[ -n "$BAG_FILE" ]]; then
  # Bag mode
  if [[ ! -f "$BAG_FILE" ]]; then
    echo "ERROR: Bag file not found: $BAG_FILE"
    exit 1
  fi
  BAG_ABS="$(realpath "$BAG_FILE")"
  DATA_DIR="$(dirname "$BAG_ABS")"
  BAG_NAME="$(basename "$BAG_ABS")"
  calib_cmd="docker run --rm --network host --ipc host \
    -e ROS_DOMAIN_ID=30 \
    -v ${DATA_DIR}:/data:rw \
    -v /tmp:/tmp \
    ${CALIB_IMAGE} \
    /usr/local/bin/calib_run.sh /data/${BAG_NAME}"
  fn_tmux_pane_run "$SESSION" "calibration" "" "$calib_cmd"
else
  # Live mode: use pre-generated config (IP discovery done above)
  if [[ ! -f "$RUNTIME_CONFIG_DIR/livox_mid360.json" ]]; then
    echo "ERROR: Livox config not found: $RUNTIME_CONFIG_DIR/livox_mid360.json"
    exit 1
  fi
  calib_cmd="docker run --rm --network host --ipc host \
    -e ROS_DOMAIN_ID=30 \
    -v ${RUNTIME_CONFIG_DIR}/livox_mid360.json:${LIVOX_CONFIG_CONTAINER}:ro \
    -v /tmp:/tmp \
    ${CALIB_IMAGE} \
    bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && pkill -f rosmaster 2>/dev/null || true; sleep 1 && roslaunch lidar_imu_init livox_mid360_integrated.launch use_rviz:=false & sleep 5 && rosrun imu_bridge_ros1 imu_receiver_node _socket_path:=/tmp/imu_bridge.sock _publish_topic:=/mavros/imu/data_raw'"
  fn_tmux_pane_run "$SESSION" "calibration" "" "$calib_cmd"
fi

# =============================================================================
# Window 4: Monitor + status
# =============================================================================
monitor_script=$(cat <<'EOF'
echo "=== Linker Integrated Monitor ===" &&
echo "" &&
echo "Services:" &&
echo "  [1] px4-connector: ROS2 IMU bridge (PX4 → /tmp/imu_bridge.sock)" &&
echo "  [2] lio: Livox driver → (wait for /livox/lidar) → Fast LIO" &&
echo "  [3] calibration: LiDAR-IMU initialization (ROS1)" &&
echo "" &&
echo "--- Container status ---" &&
echo "PX4 container: $(docker ps -q --filter ancestor=vtol/px4-connector-jetson:latest | head -1 | xargs -I{} echo {})" &&
echo "LIO container: $(docker ps -q --filter ancestor=vtol/lio-jetson:latest | head -1 | xargs -I{} echo {})" &&
echo "Calib container: $(docker ps -q --filter ancestor=vtol/calib-lidar-imu-init-jetson:latest | head -1 | xargs -I{} echo {})" &&
echo "" &&
echo "--- ROS2 topics (ROS2) ---" &&
echo "PX4 IMU: /imu_raw" &&
echo "LIO output: /cloud_registered" &&
echo "" &&
echo "--- Real-time calib result (auto-refresh 2s) ---" &&
while true; do
  if [ -f /root/catkin_ws/src/LiDAR_IMU_Init/result/Initialization_result.txt ]; then
    echo "--- $(date '+%H:%M:%S') ---"
    cat /root/catkin_ws/src/LiDAR_IMU_Init/result/Initialization_result.txt
  else
    echo "Waiting for result file..."
  fi
  sleep 2
done
EOF
)
fn_tmux_window_create_and_run_bash "$SESSION" "monitor" "$monitor_script"

# =============================================================================
# Window 5: Exec into px4-connector container
# =============================================================================
px4_shell_script="echo \"Waiting for px4-connector container...\" && \
until CONTAINER_ID=\$(docker ps -q --filter ancestor=${PX4_IMAGE}); do sleep 1; done && \
docker exec -it \$CONTAINER_ID bash -c 'source /opt/ros/humble/setup.bash && source /root/px4_connector_ws/install/setup.bash && exec bash'"
fn_tmux_window_create_and_run_bash "$SESSION" "px4-shell" "$px4_shell_script"

# =============================================================================
# Window 6: Exec into lio container
# =============================================================================
lio_shell_script="echo \"Waiting for lio container...\" && \
until CONTAINER_ID=\$(docker ps -q --filter ancestor=${LIO_IMAGE}); do sleep 1; done && \
docker exec -it \$CONTAINER_ID bash -c 'source /opt/ros/humble/setup.bash && source /root/ros2_ws/install/setup.bash && exec bash'"
fn_tmux_window_create_and_run_bash "$SESSION" "lio-shell" "$lio_shell_script"

# =============================================================================
# Window 7: Exec into calib container
# =============================================================================
calib_shell_script="echo \"Waiting for calib container...\" && \
until CONTAINER_ID=\$(docker ps -q --filter ancestor=${CALIB_IMAGE}); do sleep 1; done && \
docker exec -it \$CONTAINER_ID bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && exec bash'"
fn_tmux_window_create_and_run_bash "$SESSION" "calib-shell" "$calib_shell_script"

# Select px4-connector window for initial attention
fn_tmux_window_select "$SESSION" "px4-connector"

# Attach to session
# fn_tmux_attach "$SESSION"
echo "Session '$SESSION' started with 7 windows:"
echo "  1. px4-connector  - PX4 -> ROS2 IMU bridge"
echo "  2. lio            - Livox driver → wait /livox/lidar → Fast LIO (fastlio_mid360.yaml)"
echo "  3. calibration    - LiDAR-IMU initialization"
echo "  4. monitor        - Status & result tail"
echo "  5. px4-shell      - Exec into px4-connector container (ROS2 sourced)"
echo "  6. lio-shell      - Exec into lio container (ROS2 sourced)"
echo "  7. calib-shell    - Exec into calib container (ROS1 sourced)"
echo ""
echo "Attach: tmux attach-session -t $SESSION"
