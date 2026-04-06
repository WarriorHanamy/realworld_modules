#!/usr/bin/env bash
set -euo pipefail

docker run --rm \
  --platform linux/arm64 \
  --net=host \
  --ipc=host \
  --privileged \
  -e DISPLAY="${DISPLAY:-}" \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "${HOME}/.Xauthority:/home/ros/.Xauthority" \
  vtol/ros2-jetson:latest \
  bash -c "source /opt/ros/humble/setup.bash && source /home/ros/ros2_ws/install/setup.bash && exec bash"
