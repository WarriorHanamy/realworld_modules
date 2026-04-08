#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/px4-connector-jetson:latest"
MICRO_XRCE_DEVICE="${MICRO_XRCE_DEVICE:-/dev/ttyTHS1}"
MICRO_XRCE_BAUDRATE="${MICRO_XRCE_BAUDRATE:-921600}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FASTDDS_CONFIG="${SCRIPT_DIR}/fastdds_jetson.xml"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm \
  --net=host \
  --ipc=host \
  --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e XRCE_DOMAIN_ID_OVERRIDE=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds_jetson.xml \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds_jetson.xml:ro" \
  --entrypoint bash \
  "${IMAGE}" \
  -c "export LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH && ldconfig && MicroXRCEAgent serial --dev ${MICRO_XRCE_DEVICE} -b ${MICRO_XRCE_BAUDRATE}"
