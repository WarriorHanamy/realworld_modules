#!/usr/bin/env bash
set -euo pipefail

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
  -v "${DATA_DIR}:/data:rw" \
  vtol/calib-lidar-imu-init-jetson:latest \
  /usr/local/bin/calib_run.sh \
  "${args[@]}" \
  "/data/$(basename "${BAG}")" \
  "$@"
