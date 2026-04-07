#!/usr/bin/env bash
set -eo pipefail

docker run --rm --net=host --ipc=host vtol/lio-jetson:latest
