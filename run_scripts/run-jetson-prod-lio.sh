#!/usr/bin/env bash
set -eo pipefail

DOCKER_CPUS="6,7"  # orin nx is 0-7
INTERFACE="enP8p1s0"
IMAGE="vtol/lio-jetson:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FASTDDS_CONFIG="${SCRIPT_DIR}/fastdds_jetson.xml"
LIVOX_CONFIG_TEMPLATE="${SCRIPT_DIR}/config_livox_mid360.json"
FAST_LIO_CONFIG_TEMPLATE="${SCRIPT_DIR}/mid360.yaml"
FAST_LIO_IMU_TOPIC="/livox/imu"
FAST_LIO_EXTRINSIC_T="[ -0.011, -0.02329, 0.04412 ]"
FAST_LIO_EXTRINSIC_R="[ 1., 0., 0.,
                        0., 1., 0.,
                        0., 0., 1.]"

# Discover LiDAR IP from ARP cache
LIDAR_IP=$(ip neigh show dev "$INTERFACE" | grep -v "INCOMPLETE" | grep -v "FAILED" | awk '{print $1}' | grep -v "\.255$" | head -1)
if [ -z "$LIDAR_IP" ]; then
    echo "ERROR: No LiDAR found on $INTERFACE"
    exit 1
fi

# Get host IP on interface
HOST_IP=$(ip addr show dev "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
if [ -z "$HOST_IP" ]; then echo "ERROR: No IP on $INTERFACE"; exit 1; fi

echo "LiDAR IP: $LIDAR_IP"
echo "Host IP: $HOST_IP"

# Generate livox config from template
CONFIG_DIR="/tmp/livox-config"
mkdir -p "$CONFIG_DIR"
sed -e "s|\$HOST_IP|$HOST_IP|g" \
    -e "s|\$LIDAR_IP|$LIDAR_IP|g" \
    "$LIVOX_CONFIG_TEMPLATE" > "$CONFIG_DIR/MID360_config.json"

FAST_LIO_IMU_TOPIC="$FAST_LIO_IMU_TOPIC" \
FAST_LIO_EXTRINSIC_T="$FAST_LIO_EXTRINSIC_T" \
FAST_LIO_EXTRINSIC_R="$FAST_LIO_EXTRINSIC_R" \
python3 - "$FAST_LIO_CONFIG_TEMPLATE" "$CONFIG_DIR/mid360.yaml" <<'PY'
from pathlib import Path
import os
import sys

template = Path(sys.argv[1]).read_text()
rendered = (
    template
    .replace("$FAST_LIO_IMU_TOPIC", os.environ["FAST_LIO_IMU_TOPIC"])
    .replace("$FAST_LIO_EXTRINSIC_T", os.environ["FAST_LIO_EXTRINSIC_T"])
    .replace("$FAST_LIO_EXTRINSIC_R", os.environ["FAST_LIO_EXTRINSIC_R"])
)
Path(sys.argv[2]).write_text(rendered)
PY

# Cleanup existing containers from same image
docker ps -a --filter "ancestor=${IMAGE}" -q | xargs -r docker rm -f 2>/dev/null || true

docker run --rm \
  --net=host \
  --ipc=host \
  --cpuset-cpus="$DOCKER_CPUS" \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds_jetson.xml \
  -v "$CONFIG_DIR/MID360_config.json:/root/ros2_ws/install/livox_ros_driver2/share/livox_ros_driver2/config/MID360_config.json:ro" \
  -v "$CONFIG_DIR/mid360.yaml:/root/ros2_ws/install/fast_lio/share/fast_lio/config/mid360.yaml:ro" \
  -v "${FASTDDS_CONFIG}:/etc/fastdds/fastdds_jetson.xml:ro" \
  --entrypoint '' \
  "$IMAGE" \
  bash -c '
    set -eo pipefail
    set +u
    source /opt/ros/humble/setup.bash
    source /root/ros2_ws/install/setup.bash
    set -u

    echo "Starting Livox driver..."
    ros2 launch livox_ros_driver2 msg_MID360_launch.py &
    DRIVER_PID=$!

    echo "Waiting for /livox/lidar topic..."
    until ros2 topic list 2>/dev/null | grep -q "/livox/lidar"; do
        sleep 1
    done
    echo "/livox/lidar topic is available"

    echo "Starting Fast LIO..."
    ros2 launch fast_lio mapping.launch.py config_file:=mid360.yaml rviz:=false
'
