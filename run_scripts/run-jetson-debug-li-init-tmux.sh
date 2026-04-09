#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/tmux_utils.sh"

SESSION="li-init-test"
PX4_IMAGE="vtol/px4-connector-jetson:latest"
CALIB_IMAGE="vtol/calib-lidar-imu-init-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

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

# Cleanup old tmux session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Start tmux session
fn_tmux_session_start "$SESSION"

# Pane 1: ROS2 IMU Sender (PX4 -> Unix socket)
fn_tmux_run "$SESSION" 1 \
  "docker run --rm --network host --ipc host --privileged \
    -e ROS_DOMAIN_ID=30 \
    -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
    -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro \
    ${PX4_IMAGE} \
    bash -c 'set +u; source /opt/ros/humble/setup.bash; source /root/px4_connector_ws/install/setup.bash; set -u; ros2 launch imu_bridge sender.launch.py'"

# Split horizontally, then Pane 2: Calibration
fn_tmux_split_h "$SESSION" 1
sleep 0.3

if [[ -n "$BAG_FILE" ]]; then
  # Bag mode
  if [[ ! -f "$BAG_FILE" ]]; then
    echo "ERROR: Bag file not found: $BAG_FILE"
    exit 1
  fi
  BAG_ABS="$(realpath "$BAG_FILE")"
  DATA_DIR="$(dirname "$BAG_ABS")"
  BAG_NAME="$(basename "$BAG_ABS")"
  fn_tmux_run "$SESSION" 2 \
    "docker run --rm --network host --ipc host \
      -e ROS_DOMAIN_ID=30 \
      -v ${DATA_DIR}:/data:rw \
      ${CALIB_IMAGE} \
      /usr/local/bin/calib_run.sh /data/${BAG_NAME}"
else
  # Live mode: calibration node directly (roscore + imu_receiver + li_init)
  fn_tmux_run "$SESSION" 2 \
    "docker run --rm --network host --ipc host \
      -e ROS_DOMAIN_ID=30 \
      ${CALIB_IMAGE} \
      bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && \
               LAUNCH_FILE=\"/root/catkin_ws/src/LiDAR_IMU_Init/launch/calib_with_imu.launch\" && \
               if [ ! -f \"\$LAUNCH_FILE\" ]; then cp /dockerfiles/calib_with_imu.launch \"\$LAUNCH_FILE\"; fi && \
               roscore & sleep 3 && \
               roslaunch lidar_imu_init calib_with_imu.launch rviz:=false'"
fi

# Split horizontally again, Pane 3: Monitor + result tail
fn_tmux_split_h "$SESSION" 2
sleep 0.3
fn_tmux_run "$SESSION" 3 \
  "echo '=== LI-Init Monitor ===' && \
   echo '' && \
   echo 'Pane 1: ROS2 IMU sender → /tmp/imu_bridge.sock' && \
   echo 'Pane 2: Calibration (Mid-360)' && \
   echo '' && \
   echo '--- Real-time result ---' && \
   tail -f /root/catkin_ws/src/LiDAR_IMU_Init/result/Initialization_result.txt 2>/dev/null || \
   echo 'Waiting for result file...'"

# Attach to session
fn_tmux_attach "$SESSION"
