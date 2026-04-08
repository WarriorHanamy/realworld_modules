#!/usr/bin/env bash
set -eo pipefail

IMAGE="vtol/calib-lidar-imu-init-jetson:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FASTDDS_CONFIG="${SCRIPT_DIR}/config/fastdds-debug.xml"

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
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v "${DATA_DIR}:/data:rw" \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro" \
  "${IMAGE}" \
  /usr/local/bin/calib_run.sh \
  "${args[@]}" \
  "/data/$(basename "${BAG}")" \
  "$@"
