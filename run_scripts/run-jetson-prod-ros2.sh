#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/ros2-jetson:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FASTDDS_CONFIG="${SCRIPT_DIR}/fastdds_jetson.xml"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm \
  --platform linux/arm64 \
  --net=host \
  --ipc=host \
  --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds_jetson.xml \
  -e DISPLAY="${DISPLAY:-}" \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "${HOME}/.Xauthority:/home/ros/.Xauthority" \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds_jetson.xml:ro" \
  "${IMAGE}" \
  bash -c "set +u; source /opt/ros/humble/setup.bash && source /home/ros/ros2_ws/install/setup.bash; set -u; exec bash"
