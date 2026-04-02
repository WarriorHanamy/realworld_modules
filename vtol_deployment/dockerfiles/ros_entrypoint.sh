#!/bin/bash
set -euo pipefail

source /opt/ros/humble/setup.bash

WS_SETUP="${WS_DIR:-/root/ros2_ws}/install/setup.bash"
if [ -f "$WS_SETUP" ]; then
    source "$WS_SETUP"
fi

exec "$@"
