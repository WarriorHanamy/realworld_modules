#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/tmux_utils.sh"

IMAGE="osrf/ros:humble-desktop"
SESSION="ros2-demo"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

# Cleanup tmux session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Start tmux session
fn_tmux_session_start "$SESSION"

# Run talker in first pane
fn_tmux_run "$SESSION" 1 \
  "docker run --rm --network host --ipc host -e ROS_DOMAIN_ID=30 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro ${IMAGE} bash -c 'set +u; source /opt/ros/humble/setup.bash; set -u; ros2 run demo_nodes_cpp talker'"

# Split and run listener in second pane
fn_tmux_split_h "$SESSION" 1
sleep 0.5
fn_tmux_run "$SESSION" 2 \
  "docker run --rm --network host --ipc host -e ROS_DOMAIN_ID=30 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml -v ${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro ${IMAGE} bash -c 'set +u; source /opt/ros/humble/setup.bash; set -u; ros2 run demo_nodes_cpp listener'"

fn_tmux_attach "$SESSION"
