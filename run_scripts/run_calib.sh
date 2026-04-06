#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-$(pwd)/data}"
mkdir -p "${DATA_DIR}"

docker run --rm --net=host --ipc=host -v "${DATA_DIR}:/data:rw" \
  vtol/calib-lidar-imu-init-jetson:latest \
  /usr/local/bin/calib_run.sh "$@"
