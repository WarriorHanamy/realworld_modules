#!/usr/bin/env bash
set -euo pipefail

docker run --rm --net=host --ipc=host --privileged vtol/px4-connector-jetson:latest
