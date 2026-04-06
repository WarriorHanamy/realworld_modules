#!/usr/bin/env bash
set -euo pipefail

docker run --rm --net=host --ipc=host vtol/lio-jetson:latest
