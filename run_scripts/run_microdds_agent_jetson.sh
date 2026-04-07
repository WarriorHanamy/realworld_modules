#!/usr/bin/env bash
set -eo pipefail

MICRO_XRCE_DEVICE="${MICRO_XRCE_DEVICE:-/dev/ttyTHS1}"
MICRO_XRCE_BAUDRATE="${MICRO_XRCE_BAUDRATE:-921600}"

docker run --rm \
  --net=host \
  --ipc=host \
  --privileged \
  --entrypoint bash \
  vtol/px4-connector-jetson:latest \
  -c "export LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH && ldconfig && MicroXRCEAgent serial --dev ${MICRO_XRCE_DEVICE} -b ${MICRO_XRCE_BAUDRATE}"
