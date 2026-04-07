#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="ros:humble-ros-base"
FASTDDS_CONFIG="${SCRIPT_DIR}/fastdds_jetson.xml"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm -it \
  --network host \
  --ipc host \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds_jetson.xml \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds_jetson.xml:ro" \
  "${IMAGE}" \
  bash -c "set +u; source /opt/ros/humble/setup.bash; set -u; exec bash"
