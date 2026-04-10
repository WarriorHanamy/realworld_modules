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

SESSION="jetson-debug-calib"
IMAGE="vtol/calib-lidar-imu-init-jetson:latest"
INTERFACE="enP8p1s0"
LIVOX_CONFIG_TEMPLATE="${SCRIPT_DIR}/config/livox_mid360.json"
LIVOX_CONFIG_CONTAINER="/root/catkin_ws/src/livox_ros_driver2/config/MID360_config.json"

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

# Check image
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $IMAGE not found. Build with: make docker-build-calib-jetson"
  exit 1
fi

# Cleanup existing containers
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm 2>/dev/null || true

# Kill host-side rosmaster so container can bind port 11311
pkill -f rosmaster 2>/dev/null || true
pkill -f roscore 2>/dev/null || true

# Clean up old session and start fresh
fn_tmux_session_safe_start "$SESSION"

# Window 1: Launch calibration container (bag or live)
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
    ${IMAGE} \
    /usr/local/bin/calib_run.sh /data/${BAG_NAME}"
  fn_tmux_pane_run "$SESSION" "calibration" "" "$calib_cmd"
else
  # Live mode: discover LiDAR/Host IPs, generate config, start full stack
  RUNTIME_CONFIG_DIR="/tmp/calib-livox-config"
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
    ${IMAGE} \
    bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && pkill -f rosmaster 2>/dev/null || true; sleep 1 && roslaunch lidar_imu_init livox_mid360_integrated.launch use_rviz:=false & sleep 5 && rosrun imu_bridge_ros1 imu_receiver_node _socket_path:=/tmp/imu_bridge.sock _publish_topic:=/mavros/imu/data_raw'"
  fn_tmux_pane_run "$SESSION" "calibration" "" "$calib_cmd"
fi

# Window 2: Exec into calib container with ROS env sourced
shell_script="echo \"Waiting for calibration container...\" && \
until CONTAINER_ID=\$(docker ps -q --filter ancestor=${IMAGE}); do sleep 1; done && \
echo \"Attaching to container: \${CONTAINER_ID}\" && \
docker exec -it \${CONTAINER_ID} bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && exec bash'"
fn_tmux_window_create_and_run_bash "$SESSION" "calib-shell" "$shell_script"

# Select calibration window
fn_tmux_window_select "$SESSION" "calibration"

echo "Session '$SESSION' created."
echo "  Window 1: calibration (running)"
echo "  Window 2: calib-shell (exec with ROS1 sourced)"
echo ""
echo "Attach: tmux attach-session -t $SESSION"
