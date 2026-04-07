#!/usr/bin/env bash
set -eo pipefail

# Run Livox Mid-360 driver on lio-upstream-livox image
# Discovers LiDAR IP from ARP cache, uses mid360 config

INTERFACE="enP8p1s0"
IMAGE="vtol/lio-upstream-livox-jetson:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FASTDDS_CONFIG="${SCRIPT_DIR}/fastdds_jetson.xml"

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true
CONFIG_DIR="/tmp/livox-config"

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
mkdir -p "$CONFIG_DIR"

# Generate MID360_config.json with correct IPs
# NOTE: Using NEW format (host_net_info as array) because Livox-SDK2
# does NOT create data sockets with OLD format (host_net_info as object).
# See: https://github.com/Livox-SDK/Livox-SDK2/issues/XXX
cat > "$CONFIG_DIR/MID360_config.json" << EOF
{
  "lidar_summary_info": {
    "lidar_type": 8
  },
  "MID360": {
    "lidar_net_info": {
      "cmd_data_port": 56100,
      "push_msg_port": 56200,
      "point_data_port": 56300,
      "imu_data_port": 56400,
      "log_data_port": 56500
    },
    "host_net_info": [
      {
        "cmd_data_ip": "$HOST_IP",
        "cmd_data_port": 56101,
        "push_msg_ip": "$HOST_IP",
        "push_msg_port": 56201,
        "point_data_ip": "$HOST_IP",
        "point_data_port": 56301,
        "imu_data_ip": "$HOST_IP",
        "imu_data_port": 56401,
        "log_data_ip": "",
        "log_data_port": 56501,
        "lidar_ip": ["$LIDAR_IP"]
      }
    ]
  }
}
EOF

# Run LIO-upstream-livox container with livox_driver
docker run --rm \
  --net=host \
  --ipc=host \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds_jetson.xml \
  -v "$CONFIG_DIR/MID360_config.json:/root/ros2_ws/install/livox_ros_driver2/share/livox_ros_driver2/config/MID360_config.json:ro" \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds_jetson.xml:ro" \
  --entrypoint '' \
  "${IMAGE}" \
  bash -c 'set +u && source /opt/ros/humble/setup.bash && source /root/ros2_ws/install/setup.bash && set -u && ros2 launch livox_ros_driver2 msg_MID360_launch.py'