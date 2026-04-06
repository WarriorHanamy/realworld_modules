#!/usr/bin/env bash
set -euo pipefail

docker run --rm --platform linux/arm64 --net=host --ipc=host --privileged \
  vtol/ros2-jetson:latest
