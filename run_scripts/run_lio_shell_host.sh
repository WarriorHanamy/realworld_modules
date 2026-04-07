#!/usr/bin/env bash
set -euo pipefail

# Grant X11 access to Docker (optional, for GUI apps launched inside shell)
xhost +local:docker 2>/dev/null || true

docker run --rm -it \
  --net=host \
  --ipc=host \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY="${DISPLAY}" \
  -v "${HOME}/.Xauthority:/root/.Xauthority:ro" \
  --entrypoint bash \
  vtol/fastlio-debug-host:latest