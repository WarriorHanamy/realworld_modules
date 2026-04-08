#!/bin/bash
set -eo pipefail

# Run Livox Mid-360 driver on lio image
# Discovers LiDAR IP from ARP cache, uses mid360 config

INTERFACE="enP8p1s0"
LIO_IMAGE="vtol/lio-jetson:latest"
CONTAINER_NAME="livox-driver-jetson"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
FASTDDS_CONFIG="${CONFIG_DIR}/fastdds-local.xml"
LIVOX_CONFIG_TEMPLATE="${CONFIG_DIR}/livox_mid360.json"

# Cleanup existing container with same name
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
RUNTIME_CONFIG_DIR="/tmp/livox-config"

# Discover LiDAR IP from ARP cache
LIDAR_IP=$(ip neigh show dev "$INTERFACE" | grep -v "INCOMPLETE" | grep -v "FAILED" | awk '{print $1}' | grep -v "\.255$" | head -1)
if [ -z "$LIDAR_IP" ]; then
    echo "ERROR: No LiDAR found on $INTERFACE"
    exit 1
fi

# Get host IP on enP8p1s0 interface
HOST_IP=$(ip addr show dev "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
if [ -z "$HOST_IP" ]; then echo "ERROR: No IP on $INTERFACE"; exit 1; fi

echo "LiDAR IP: $LIDAR_IP"
echo "Host IP: $HOST_IP"

# Create temporary config directory
mkdir -p "$RUNTIME_CONFIG_DIR"

# Generate MID360_config.json from template with correct IPs
# NOTE: Using NEW format (host_net_info as array) because Livox-SDK2
# does NOT create data sockets with OLD format (host_net_info as object).
if [ ! -f "$LIVOX_CONFIG_TEMPLATE" ]; then
    echo "ERROR: Livox config template not found: $LIVOX_CONFIG_TEMPLATE"
    exit 1
fi

sed -e "s|\$HOST_IP|$HOST_IP|g" \
    -e "s|\$LIDAR_IP|$LIDAR_IP|g" \
    "$LIVOX_CONFIG_TEMPLATE" > "$RUNTIME_CONFIG_DIR/livox_mid360.json"

# Run LIO container with bash entrypoint
docker run --rm \
  --name "${CONTAINER_NAME}" \
  --net=host \
  --ipc=host \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  -v "$RUNTIME_CONFIG_DIR/livox_mid360.json:/root/ros2_ws/install/livox_ros_driver2/share/livox_ros_driver2/config/MID360_config.json:ro" \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds.xml:ro" \
  --entrypoint '' \
  "$LIO_IMAGE" \
  bash -c 'set +u && source /opt/ros/humble/setup.bash && source /root/ros2_ws/install/setup.bash && set -u && ros2 launch livox_ros_driver2 msg_MID360_launch.py'
