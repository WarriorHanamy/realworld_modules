#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/calib-lidar-imu-init-jetson:latest"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

BAG="${1:?Usage: run_calib.sh <bag_file> [options]}"
shift

DATA_DIR="${DATA_DIR:-$(pwd)/data}"
LAUNCH="${LAUNCH:-mid360.launch}"
PLAY_RATE="${PLAY_RATE:-}"

mkdir -p "${DATA_DIR}"

args=()
if [ -n "${LAUNCH}" ]; then
  args+=(--launch "${LAUNCH}")
fi
if [ -n "${PLAY_RATE}" ]; then
  args+=(--rate "${PLAY_RATE}")
fi

docker run --rm \
  --net=host \
  --ipc=host \
  -e ROS_DOMAIN_ID=30 \
  -v "${DATA_DIR}:/data:rw" \
  "${IMAGE}" \
  /usr/local/bin/calib_run.sh \
  "${args[@]}" \
  "/data/$(basename "${BAG}")" \
  "$@"
