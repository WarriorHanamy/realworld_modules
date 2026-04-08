#!/bin/bash
set -eo pipefail

# Discover devices on enP8p1s0 interface
# Returns all devices with valid MAC addresses

INTERFACE="enP8p1s0"  # see the orin nx device

ip neigh show dev "$INTERFACE" | grep -v "INCOMPLETE" | grep -v "FAILED" | awk '{print $1}' | grep -v "\.255$"
