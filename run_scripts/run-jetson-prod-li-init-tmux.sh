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

SESSION="jetson-debug-li-init"
PX4_IMAGE="vtol/px4-connector-jetson:latest"
CALIB_IMAGE="vtol/calib-lidar-imu-init-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"
INTERFACE="enP8p1s0"
LIVOX_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/livox_mid360.json"
LIVOX_CONFIG_CONTAINER="/root/catkin_ws/src/livox_ros_driver2/config/MID360_config.json"

# Validate config file
if [[ ! -f "$FASTDDS_CONFIG" ]]; then
  echo "ERROR: FastDDS config not found: $FASTDDS_CONFIG"
  exit 1
fi

# Parse arguments
BAG_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $0 [--bag <bagfile>]"
      echo "  --bag <file>   Play bag file instead of live sensor"
      exit 0
      ;;
    --bag) BAG_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Check images
if ! docker image inspect "$PX4_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $PX4_IMAGE not found. Build with: make docker-build-px4-connector-jetson"
  exit 1
fi
if ! docker image inspect "$CALIB_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $CALIB_IMAGE not found. Build with: make docker-build-calib-jetson"
  exit 1
fi

# Cleanup existing containers from same images
echo "Cleaning up existing containers from $PX4_IMAGE and $CALIB_IMAGE..."
docker ps -a --filter "ancestor=${PX4_IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${PX4_IMAGE}" -q | xargs -r docker rm 2>/dev/null || true
docker ps -a --filter "ancestor=${CALIB_IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${CALIB_IMAGE}" -q | xargs -r docker rm 2>/dev/null || true

# Kill host-side rosmaster so container can bind port 11311
pkill -f rosmaster 2>/dev/null || true
pkill -f roscore 2>/dev/null || true

# Clean up old session and start fresh
fn_tmux_session_safe_start "$SESSION"

# Rename default window to imu-sender
fn_tmux_window_rename "$SESSION" "main" "imu-sender"

# Window 1: ROS2 IMU Sender (PX4 -> Unix socket)
imu_sender_cmd="docker run --rm --network host --ipc host --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro \
  -v /tmp:/tmp \
  ${PX4_IMAGE} \
   bash -c 'set +u; source /opt/ros/humble/setup.bash; source /root/px4_connector_ws/install/setup.bash; set -u; ros2 launch imu_bridge sender.launch.py output_mode:=socket'"
fn_tmux_pane_run "$SESSION" "imu-sender" "" "$imu_sender_cmd"

# Window 2: Calibration (bag playback or live sensor)
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
  # Live mode: discover LiDAR/Host IPs, generate config, start full stack
  RUNTIME_CONFIG_DIR="/tmp/li-init-livox-config"
  mkdir -p "$RUNTIME_CONFIG_DIR"
  HOST_IP=$(ip addr show dev "$INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
  LIDAR_IP=$(ip neigh show dev "$INTERFACE" 2>/dev/null | grep -v "INCOMPLETE" | grep -v "FAILED" | awk '{print $1}' | grep -v "\.255$" | head -1)
  if [[ -z "$HOST_IP" || -z "$LIDAR_IP" ]]; then
    echo "ERROR: Could not discover IPs on $INTERFACE (HOST_IP=${HOST_IP:-<empty>} LIDAR_IP=${LIDAR_IP:-<empty>})"
    exit 1
  fi
  echo "LiDAR IP: $LIDAR_IP  Host IP: $HOST_IP"
  sed -e "s|\\\$HOST_IP|${HOST_IP}|g" \
      -e "s|\\\$LIDAR_IP|${LIDAR_IP}|g" \
      "$LIVOX_CONFIG_TEMPLATE" > "$RUNTIME_CONFIG_DIR/livox_mid360.json"
  calib_cmd="docker run --rm --network host --ipc host \
    -e ROS_DOMAIN_ID=30 \
    -v ${RUNTIME_CONFIG_DIR}/livox_mid360.json:${LIVOX_CONFIG_CONTAINER}:ro \
    -v /tmp:/tmp \
    ${CALIB_IMAGE} \
    bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && pkill -f rosmaster 2>/dev/null || true; sleep 1 && roslaunch lidar_imu_init livox_mid360_integrated.launch use_rviz:=false & sleep 5 && rosrun imu_bridge_ros1 imu_receiver_node _socket_path:=/tmp/imu_bridge.sock _publish_topic:=/mavros/imu/data_raw'"
  fn_tmux_pane_run "$SESSION" "calibration" "" "$calib_cmd"
fi

# Window 3: Monitor + result tail
monitor_script=$(cat <<'EOF'
echo "=== LI-Init Monitor ===" &&
echo "" &&
echo "Window 1 (imu-sender): ROS2 IMU → /tmp/imu_bridge.sock" &&
echo "Window 2 (calibration): ROS1 calibration (Mid-360)" &&
echo "" &&
echo "--- Real-time result (auto-refresh 2s) ---" &&
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

# Window 4: Exec into calib container (bash)
calib_shell_script="echo \"Waiting for calib container...\" &&
until CONTAINER_ID=\$(docker ps -q --filter ancestor=${CALIB_IMAGE}); do sleep 1; done &&
docker exec -it \$CONTAINER_ID bash -c'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && exec bash'"
fn_tmux_window_create_and_run_bash "$SESSION" "calib-shell" "$calib_shell_script"

# Select calibration window for attention
fn_tmux_window_select "$SESSION" "calibration"

# fn_tmux_attach "$SESSION"
echo "Session '$SESSION' started."
echo "  Window 1: imu-sender (ROS2 IMU bridge)"
echo "  Window 2: calibration (LiDAR-IMU initialization)"
echo "  Window 3: monitor (status & result tail)"
echo "  Window 4: calib-shell (exec into calib container)"
echo ""
echo "Attach: tmux attach-session -t $SESSION"
