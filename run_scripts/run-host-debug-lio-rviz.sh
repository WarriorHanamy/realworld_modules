#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RVIZ_CONFIG="${SCRIPT_DIR}/config/fastlio.rviz"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

if [ ! -f "${RVIZ_CONFIG}" ]; then
  echo "Error: RViz config not found: ${RVIZ_CONFIG}" >&2
  exit 1
fi

# Grant X11 access to Docker
xhost +local:docker 2>/dev/null || true

docker run --rm -it \
  --net=host \
  --ipc=host \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY="${DISPLAY}" \
  -v "${HOME}/.Xauthority:/root/.Xauthority:ro" \
  -v "${RVIZ_CONFIG}:/fastlio.rviz:ro" \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro" \
  vtol/fastlio-debug-host:latest \
  rviz2 -d /fastlio.rviz
