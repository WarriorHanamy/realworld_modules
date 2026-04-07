#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RVIZ_CONFIG="${SCRIPT_DIR}/../tools/dockerfiles/fastlio.rviz"

if [ ! -f "${RVIZ_CONFIG}" ]; then
  echo "Error: RViz config not found: ${RVIZ_CONFIG}" >&2
  exit 1
fi

# Grant X11 access to Docker
xhost +local:docker 2>/dev/null || true

docker run --rm -it \
  --net=host \
  --ipc=host \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY="${DISPLAY}" \
  -v "${HOME}/.Xauthority:/root/.Xauthority:ro" \
  -v "${RVIZ_CONFIG}:/fastlio.rviz:ro" \
  vtol/fastlio-debug-host:latest \
  rviz2 -d /fastlio.rviz