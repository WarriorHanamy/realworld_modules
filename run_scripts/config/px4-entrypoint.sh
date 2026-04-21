#!/usr/bin/env bash
set -eo pipefail
WS_DIR="${WS_DIR:-/home/ros/ros2_ws}"

cleanup() {
  if [[ -n "${frontend_pid:-}" ]]; then
    kill "${frontend_pid}" 2>/dev/null || true
  fi
  if [[ -n "${imu_pid:-}" ]]; then
    kill "${imu_pid}" 2>/dev/null || true
  fi
  if [[ -n "${agent_pid:-}" ]]; then
    kill "${agent_pid}" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

set +u
source /opt/ros/humble/setup.bash
source "${WS_DIR}/install/setup.bash"
set -u

echo "Starting Micro XRCE-DDS Agent..."
MicroXRCEAgent serial --dev "${MICRO_XRCE_DEVICE}" -b "${MICRO_XRCE_BAUDRATE}" &
agent_pid=$!

echo "Waiting 5 seconds for Micro XRCE-DDS Agent..."
sleep 5

echo "Starting imu_bridge sender..."
ros2 launch imu_bridge sender.launch.py \
  output_mode:="${OUTPUT_MODE}" \
  output_topic:="${IMU_OUTPUT_TOPIC}" &
imu_pid=$!

echo "Starting px4_odometry_bridge..."
ros2 launch px4_odometry_bridge bridge.launch.py &
frontend_pid=$!

wait -n "${agent_pid}" "${imu_pid}" "${frontend_pid}"
