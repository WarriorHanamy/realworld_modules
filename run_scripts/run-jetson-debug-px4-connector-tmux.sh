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

SESSION="jetson-debug-px4-connector"
IMAGE="vtol/px4-connector-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"
ROS2_WS_DIR="/home/ros/ros2_ws"

# Validate config file
if [[ ! -f "$FASTDDS_CONFIG" ]]; then
  echo "ERROR: FastDDS config not found: $FASTDDS_CONFIG"
  exit 1
fi

# Check image
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $IMAGE not found. Build with: make docker-build-px4-connector-jetson"
  exit 1
fi

# Cleanup existing containers
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm 2>/dev/null || true

# Clean up old session and start fresh
fn_tmux_session_safe_start "$SESSION"

# Window 1: Launch px4-connector container
fn_tmux_window_new "$SESSION" "px4-connector"
launch_cmd="docker run --rm --network host --ipc host --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e XRCE_DOMAIN_ID_OVERRIDE=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro \
  -v /tmp:/tmp \
  ${IMAGE} \
  bash -c 'set +u; source /opt/ros/humble/setup.bash; source ${ROS2_WS_DIR}/install/setup.bash; set -u; ros2 launch imu_bridge sender.launch.py'"
fn_tmux_pane_run "$SESSION" "px4-connector" "" "$launch_cmd"

# Window 2: Exec into px4-connector container with ROS env sourced
shell_script="echo \"Waiting for px4-connector container...\" && \
until CONTAINER_ID=\$(docker ps -q --filter ancestor=${IMAGE}); do sleep 1; done && \
echo \"Attaching to container: \${CONTAINER_ID}\" && \
docker exec -it \${CONTAINER_ID} bash -c 'source /opt/ros/humble/setup.bash && source ${ROS2_WS_DIR}/install/setup.bash && exec bash'"
fn_tmux_window_create_and_run_bash "$SESSION" "px4-shell" "$shell_script"

# Select px4-connector window
fn_tmux_window_select "$SESSION" "px4-connector"

echo "Session '$SESSION' started."
echo "  Window 1: px4-connector (running)"
echo "  Window 2: px4-shell (exec with ROS2 sourced)"
echo ""
echo "Attach: tmux attach-session -t $SESSION"
