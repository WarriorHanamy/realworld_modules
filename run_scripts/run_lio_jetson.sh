#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/lio-jetson:latest"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=30 "${IMAGE}"
