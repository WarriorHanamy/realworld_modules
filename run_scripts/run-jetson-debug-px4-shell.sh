#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="vtol/px4-connector-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm -it \
  --network host \
  --ipc host \
  --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e XRCE_DOMAIN_ID_OVERRIDE=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro" \
  --entrypoint bash \
  "${IMAGE}" \
  -c 'set +u; source /opt/ros/humble/setup.bash; source "${WS_DIR:-/root/px4_connector_ws}/install/setup.bash"; set -u; exec bash'
