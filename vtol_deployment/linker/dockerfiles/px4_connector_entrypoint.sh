#!/bin/bash
set -euo pipefail

source /opt/ros/humble/setup.bash

WS_SETUP="${WS_DIR:-/root/px4_connector_ws}/install/setup.bash"
if [ -f "$WS_SETUP" ]; then
    source "$WS_SETUP"
fi

MICRO_XRCE_DEVICE="${MICRO_XRCE_DEVICE:-/dev/ttyTHS1}"
MICRO_XRCE_BAUDRATE="${MICRO_XRCE_BAUDRATE:-921600}"

MicroXRCEAgent serial --dev "$MICRO_XRCE_DEVICE" -b "$MICRO_XRCE_BAUDRATE" &
agent_pid=$!

cleanup() {
    kill "$agent_pid" 2>/dev/null || true
}

trap cleanup EXIT

exec "$@"
