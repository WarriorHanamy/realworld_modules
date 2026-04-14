#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

# Grant X11 access to Docker
xhost +local:docker 2>/dev/null || true

docker run --rm \
  --network host \
  --ipc host \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY="${DISPLAY}" \
  -v "${HOME}/.Xauthority:/root/.Xauthority:ro" \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro" \
  --entrypoint bash \
  vtol/plotjuggler-host:latest -c '\
    source /opt/ros/humble/setup.bash && \
    source /root/ros2_ws/install/setup.bash && \
    ros2 run plotjuggler plotjuggler'
