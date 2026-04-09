#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/lio-jetson:latest"

# Find running container from this image
CONTAINER_NAME=$(docker ps --filter "ancestor=${IMAGE}" --filter "status=running" --format "{{.Names}}" | head -1)

if [ -z "${CONTAINER_NAME}" ]; then
  echo "Error: No running container found for image ${IMAGE}"
  echo "Please start the lio service first: ./run_scripts/run-jetson-prod-lio.sh"
  exit 1
fi

echo "Attaching to container: ${CONTAINER_NAME}"

docker exec -it \
  --env ROS_DOMAIN_ID=30 \
  --env RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  --env FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  "${CONTAINER_NAME}" \
  bash -c 'source /opt/ros/humble/setup.bash && source /root/ros2_ws/install/setup.bash && exec bash'
