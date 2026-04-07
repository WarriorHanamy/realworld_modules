#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/px4-connector-jetson:latest"
MICRO_XRCE_DEVICE="${MICRO_XRCE_DEVICE:-/dev/ttyTHS1}"
MICRO_XRCE_BAUDRATE="${MICRO_XRCE_BAUDRATE:-921600}"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm \
  --net=host \
  --ipc=host \
  --privileged \
  -e ROS_DOMAIN_ID=30 \
  --entrypoint bash \
  "${IMAGE}" \
  -c "export LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH && ldconfig && MicroXRCEAgent serial --dev ${MICRO_XRCE_DEVICE} -b ${MICRO_XRCE_BAUDRATE}"
