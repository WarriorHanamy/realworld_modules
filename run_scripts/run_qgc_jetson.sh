#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/qgc5-jetson:latest"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm \
  --platform linux/arm64 \
  --net=host \
  --ipc=host \
  --privileged \
  -e DISPLAY="${DISPLAY:-}" \
  -e QT_X11_NO_MITSHM=1 \
  -e ACCEPT_EULA=Y \
  -e PRIVACY_CONSENT=Y \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "${HOME}/.Xauthority:/home/qgc/.Xauthority" \
  "${IMAGE}" \
  qgc