#!/bin/bash
set -euo pipefail

source /opt/ros/noetic/setup.bash

WS_SETUP="${WS_DIR:-/root/catkin_ws}/devel/setup.bash"
if [ -f "$WS_SETUP" ]; then
    source "$WS_SETUP"
fi

cd "${WS_DIR}"

exec "$@"
