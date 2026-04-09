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

SESSION="lio"
IMAGE="vtol/lio-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

# Validate config file
if [[ ! -f "$FASTDDS_CONFIG" ]]; then
  echo "ERROR: FastDDS config not found: $FASTDDS_CONFIG"
  exit 1
fi

# Check image
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: Image $IMAGE not found. Build with: make docker-build-lio-jetson"
  exit 1
fi

# Cleanup existing containers
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker stop 2>/dev/null || true
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm 2>/dev/null || true

# Cleanup old tmux session
fn_tmux_session_kill "$SESSION"

# Start tmux session
fn_tmux_session_start "$SESSION"

# Window 1: Launch lio container (FastLIO + Livox driver)
fn_tmux_window_new "$SESSION" "lio"
launch_cmd="docker run --rm --network host --ipc host --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro \
  -v /tmp:/tmp \
  ${IMAGE} \
  bash -c 'set +u; source /opt/ros/humble/setup.bash; source /root/ros2_ws/install/setup.bash; set -u; ros2 launch livox_ros_driver2 ros2_ros__init.launch.py && ros2 launch fast_lio mapping_ros2.launch'"
fn_tmux_pane_run "$SESSION" "lio" "" "$launch_cmd"

# Window 2: Exec into lio container with ROS env sourced
shell_script="echo \"Waiting for lio container...\" && \
until CONTAINER_ID=\$(docker ps -q --filter ancestor=${IMAGE}); do sleep 1; done && \
echo \"Attaching to container: \${CONTAINER_ID}\" && \
docker exec -it \${CONTAINER_ID} bash -c 'source /opt/ros/humble/setup.bash && source /root/ros2_ws/install/setup.bash && exec bash'"
fn_tmux_window_create_and_run_bash "$SESSION" "lio-shell" "$shell_script"

# Select lio window
fn_tmux_window_select "$SESSION" "lio"

echo "Session '$SESSION' created."
echo "  Window 1: lio (running FastLIO + Livox driver)"
echo "  Window 2: lio-shell (exec with ROS2 sourced)"
echo ""
echo "Attach: tmux attach-session -t $SESSION"
