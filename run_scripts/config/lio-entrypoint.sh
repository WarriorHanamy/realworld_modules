#!/usr/bin/env bash
set -eo pipefail
WS_DIR="${WS_DIR:-/home/ros/ros2_ws}"
set +u
source /opt/ros/humble/setup.bash
source "${WS_DIR}/install/setup.bash"
set -u

echo "Starting Livox driver..."
ros2 launch livox_ros_driver2 msg_MID360_launch.py &
DRIVER_PID=$!

echo "Waiting for /livox/lidar topic..."
until ros2 topic list 2>/dev/null | grep -q "/livox/lidar"; do
    sleep 1
done
echo "/livox/lidar topic is available"

echo "Waiting for /px4/imu topic..."
until ros2 topic list 2>/dev/null | grep -q "/px4/imu"; do
    sleep 1
done
echo "/px4/imu topic is available"

echo "Starting Fast LIO..."
ros2 launch fast_lio mapping.launch.py config_file:=mid360.yaml rviz:=false
