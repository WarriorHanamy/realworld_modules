#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="vtol/px4-connector-jetson:latest"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

# Find running container from this image
CONTAINER_NAME=$(docker ps --filter "ancestor=${IMAGE}" --filter "status=running" --format "{{.Names}}" | head -1)

if [ -z "${CONTAINER_NAME}" ]; then
  echo "Error: No running container found for image ${IMAGE}"
  echo "Please start the px4-connector first: ./run_scripts/run-jetson-prod-px4-connector.sh"
  exit 1
fi

echo "Attaching to container: ${CONTAINER_NAME}"

docker exec -it \
  --env ROS_DOMAIN_ID=30 \
  --env XRCE_DOMAIN_ID_OVERRIDE=30 \
  --env RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  --env FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  "${CONTAINER_NAME}" \
  bash -c 'source /opt/ros/humble/setup.bash && source /root/px4_connector_ws/install/setup.bash && exec bash'
