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

SESSION="linker-integrated"
PX4_IMAGE="vtol/px4-connector-jetson:latest"
LIO_IMAGE="vtol/lio-jetson:latest"
CALIB_IMAGE="vtol/calib-lidar-imu-init-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

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

# Cleanup old tmux session
fn_tmux_session_kill "$SESSION"

# Start tmux session (creates window "main")
fn_tmux_session_start "$SESSION"

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
  -v /tmp:/tmp \
  ${LIO_IMAGE} \
  bash -c 'set +u; source /opt/ros/humble/setup.bash; source /root/ros2_ws/install/setup.bash; set -u; ros2 launch livox_ros_driver2 ros2_ros__init.launch.py && ros2 launch fast_lio mapping_ros2.launch'"
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
  # Live mode: calibration node directly (roscore + imu_receiver + li_init)
  calib_cmd="docker run --rm --network host --ipc host \
    -e ROS_DOMAIN_ID=30 \
    -v /tmp:/tmp \
    ${CALIB_IMAGE} \
    bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && LAUNCH_FILE=\"/root/catkin_ws/src/LiDAR_IMU_Init/launch/calib_with_imu.launch\" && if [ ! -f \"\$LAUNCH_FILE\" ]; then cp /dockerfiles/calib_with_imu.launch \"\$LAUNCH_FILE\"; fi && roscore & sleep 3 && roslaunch lidar_imu_init calib_with_imu.launch rviz:=false'"
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
echo "  [2] lio: FastLIO + Livox Mid-360 driver" &&
echo "  [3] calibration: LiDAR-IMU initialization (ROS1)" &&
echo "" &&
echo "--- Container status ---" &&
echo "PX4 container: \$(docker ps -q --filter ancestor=vtol/px4-connector-jetson:latest | head -1 | xargs -I{} echo {})" &&
echo "LIO container: \$(docker ps -q --filter ancestor=vtol/lio-jetson:latest | head -1 | xargs -I{} echo {})" &&
echo "Calib container: \$(docker ps -q --filter ancestor=vtol/calib-lidar-imu-init-jetson:latest | head -1 | xargs -I{} echo {})" &&
echo "" &&
echo "--- ROS2 topics (ROS2) ---" &&
echo "PX4 IMU: /imu_raw" &&
echo "LIO output: /cloud_registered" &&
echo "" &&
echo "--- Real-time calib result (auto-refresh 2s) ---" &&
while true; do
  if [ -f /root/catkin_ws/src/LiDAR_IMU_Init/result/Initialization_result.txt ]; then
    echo "--- \$(date '+%H:%M:%S') ---"
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
echo "Session '$SESSION' created with 7 windows:"
echo "  1. px4-connector  - PX4 → ROS2 IMU bridge"
echo "  2. lio            - FastLIO + Livox driver"
echo "  3. calibration    - LiDAR-IMU initialization"
echo "  4. monitor        - Status & result tail"
echo "  5. px4-shell      - Exec into px4-connector container (ROS2 sourced)"
echo "  6. lio-shell      - Exec into lio container (ROS2 sourced)"
echo "  7. calib-shell    - Exec into calib container (ROS1 sourced)"
echo ""
echo "To attach manually: tmux attach-session -t $SESSION"
echo "To kill session:  tmux kill-session -t $SESSION"
