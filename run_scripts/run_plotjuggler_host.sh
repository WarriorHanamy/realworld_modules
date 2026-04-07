#!/usr/bin/env bash
set -euo pipefail

# Grant X11 access to Docker
xhost +local:docker 2>/dev/null || true

docker run --rm \
  --network host \
  --ipc host \
  -e ROS_DOMAIN_ID=30 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY="${DISPLAY}" \
  -v "${HOME}/.Xauthority:/root/.Xauthority:ro" \
  vtol/plotjuggler-host:latest