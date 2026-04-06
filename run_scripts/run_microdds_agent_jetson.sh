#!/usr/bin/env bash
set -euo pipefail

MICRO_XRCE_DEVICE="${MICRO_XRCE_DEVICE:-/dev/ttyTHS1}"
MICRO_XRCE_BAUDRATE="${MICRO_XRCE_BAUDRATE:-921600}"

docker run --rm \
  --net=host \
  --ipc=host \
  --privileged \
  --entrypoint bash \
  vtol/px4-connector-jetson:latest \
  -c "MicroXRCEAgent serial --dev ${MICRO_XRCE_DEVICE} -b ${MICRO_XRCE_BAUDRATE}"
