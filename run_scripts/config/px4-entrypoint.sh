#!/usr/bin/env bash
set -eo pipefail
WS_DIR="${WS_DIR:-/home/ros/ros2_ws}"

set +u
source /opt/ros/humble/setup.bash
source "${WS_DIR}/install/setup.bash"
set -u

MICRO_XRCE_DEVICE="${MICRO_XRCE_DEVICE:-/dev/ttyTHS1}"
MICRO_XRCE_BAUDRATE="${MICRO_XRCE_BAUDRATE:-921600}"
OUTPUT_MODE="${OUTPUT_MODE:-topic}"
IMU_OUTPUT_TOPIC="${IMU_OUTPUT_TOPIC:-/px4/imu}"
SOCKET_PATH="${SOCKET_PATH:-/tmp/imu_bridge.sock}"

echo "Starting Micro XRCE-DDS Agent..."
MicroXRCEAgent serial --dev "${MICRO_XRCE_DEVICE}" -b "${MICRO_XRCE_BAUDRATE}" &

echo "Waiting 3 seconds for Micro XRCE-DDS Agent..."
sleep 3

case "${OUTPUT_MODE}" in
  topic)
    LAUNCH_FILE="px4_connector_topic.launch.py"
    echo "Starting px4_connector in topic mode..."
    exec ros2 launch px4_connector "${LAUNCH_FILE}" output_topic:="${IMU_OUTPUT_TOPIC}"
    ;;
  socket)
    LAUNCH_FILE="px4_connector_socket.launch.py"
    echo "Starting px4_connector in socket mode..."
    exec ros2 launch px4_connector "${LAUNCH_FILE}" socket_path:="${SOCKET_PATH}"
    ;;
  *)
    echo "[ERROR] Unsupported OUTPUT_MODE: ${OUTPUT_MODE} (expected: topic|socket)" >&2
    exit 1
    ;;
esac
