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

SESSION="calib"
IMAGE="vtol/calib-lidar-imu-init-jetson:latest"

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

# Cleanup old tmux session
fn_tmux_session_kill "$SESSION"

# Start tmux session
fn_tmux_session_start "$SESSION"

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
  # Live mode
  calib_cmd="docker run --rm --network host --ipc host \
    -e ROS_DOMAIN_ID=30 \
    -v /tmp:/tmp \
    ${IMAGE} \
    bash -c 'source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && LAUNCH_FILE=\"/root/catkin_ws/src/LiDAR_IMU_Init/launch/calib_with_imu.launch\" && if [ ! -f \"\$LAUNCH_FILE\" ]; then cp /dockerfiles/calib_with_imu.launch \"\$LAUNCH_FILE\"; fi && roscore & sleep 3 && roslaunch lidar_imu_init calib_with_imu.launch rviz:=false'"
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
