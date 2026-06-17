#!/usr/bin/env bash
# =============================================================================
# Bringup monitor — verify LIO pipeline health from the bringup container.
#
# Checks topic presence and rate for the core sensor pipeline:
#   /livox/imu, /px4/imu, /Odometry
#
# Usage:
#   bash /home/ros/bringup/scripts/monitor.sh
#
# All topics use standard ROS2 message types (sensor_msgs/Imu, nav_msgs/Odometry)
# available in the base ROS2 install — no additional compilation needed.
# =============================================================================
set -eo pipefail

ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-30}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"

export ROS_DOMAIN_ID
export RMW_IMPLEMENTATION

set +u
source /opt/ros/humble/setup.bash
set -u

echo ""
echo "=== Bringup Monitor: LIO Pipeline ==="
echo "  ROS_DOMAIN_ID=$ROS_DOMAIN_ID"
echo "  RMW=$RMW_IMPLEMENTATION"
echo ""

# --- topic existence check ---
check_topic() {
    local topic=$1 label=$2
    if timeout 3 ros2 topic list 2>/dev/null | grep -Fxq "$topic"; then
        echo -e "  [\xE2\x9C\x93] $label  ($topic)"
        return 0
    else
        echo -e "  [\xE2\x9C\x97] $label  ($topic — not found)"
        return 1
    fi
}

# --- topic rate check (needs type definitions) ---
check_rate() {
    local topic=$1 label=$2 window=${3:-5}
    local rate_str

    rate_str=$(timeout $((window + 3)) ros2 topic hz "$topic" --window "$window" 2>/dev/null \
        | grep "average rate:" | awk '{print $3}' || true)

    if [ -z "$rate_str" ]; then
        echo -e "  [\xE2\x9C\x97] $label rate  (no data)"
    else
        echo -e "  [\xE2\x9C\x93] $label rate  ${rate_str} Hz"
    fi
}

echo "--- Topic Presence ---"
check_topic "/livox/imu"   "/livox/imu"
check_topic "/px4/imu"     "/px4/imu"
check_topic "/Odometry"    "/Odometry"

echo ""
echo "--- Topic Rates (${TOTAL_TIMEOUT}s sampling) ---"
check_rate "/livox/imu"   "/livox/imu"   5
check_rate "/px4/imu"     "/px4/imu"     5
check_rate "/Odometry"    "/Odometry"    5

echo ""
echo "=== Monitor Complete ==="
echo ""
echo "Quick commands:"
echo "  ros2 topic echo /Odometry"
echo "  ros2 topic echo /px4/imu"
echo "  ros2 topic info /Odometry"
echo ""
