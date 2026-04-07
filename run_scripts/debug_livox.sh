#!/bin/bash
set -eo pipefail

# Debug script for Livox ROS2 topics
IMAGE="vtol/lio-jetson:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Livox ROS2 Debug ==="
echo "1. Checking running containers..."
docker ps

echo ""
echo "2. Container logs (if any)..."
CONTAINER_ID=$(docker ps -q --filter ancestor="$IMAGE" | head -1)
if [ -n "$CONTAINER_ID" ]; then
    echo "Container ID: $CONTAINER_ID"
    echo "Last 20 lines of logs:"
    docker logs --tail 20 "$CONTAINER_ID"
    
    echo ""
    echo "3. Entering container to check ROS2 topics..."
    docker exec -it "$CONTAINER_ID" bash -c '
        set +u
        source /opt/ros/humble/setup.bash
        source /root/ros2_ws/install/setup.bash
        set -u
        
        echo "ROS_DOMAIN_ID: $ROS_DOMAIN_ID"
        echo "RMW_IMPLEMENTATION: $RMW_IMPLEMENTATION"
        echo "FASTRTPS_DEFAULT_PROFILES_FILE: $FASTRTPS_DEFAULT_PROFILES_FILE"
        
        echo ""
        echo "=== ROS2 Node List ==="
        ros2 node list
        
        echo ""
        echo "=== ROS2 Topic List ==="
        ros2 topic list
        
        echo ""
        echo "=== ROS2 Topic Info (if topics exist) ==="
        for topic in /livox/lidar /livox/imu; do
            if ros2 topic list | grep -q "$topic"; then
                echo "Topic $topic exists!"
                ros2 topic info "$topic"
            else
                echo "Topic $topic NOT found"
            fi
        done
        
        echo ""
        echo "=== ROS2 Topic HZ (if topics exist) ==="
        for topic in /livox/lidar /livox/imu; do
            if ros2 topic list | grep -q "$topic"; then
                echo "Checking Hz for $topic (5 second sample)..."
                timeout 5 ros2 topic hz "$topic" || echo "No messages on $topic"
            fi
        done
    '
else
    echo "No running container found. Starting one for debugging..."
    docker run --rm -it \
      --net=host \
      --ipc=host \
      -e ROS_DOMAIN_ID=30 \
      -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
      -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds_jetson.xml \
      -v "/tmp/livox-config/MID360_config.json:/root/ros2_ws/install/livox_ros_driver2/share/livox_ros_driver2/config/MID360_config.json:ro" \
      -v "${SCRIPT_DIR}/fastdds_jetson.xml:/etc/fastdds/fastdds_jetson.xml:ro" \
      --entrypoint '' \
      "$IMAGE" \
      bash -c '
        set +u
        source /opt/ros/humble/setup.bash
        source /root/ros2_ws/install/setup.bash
        set -u
        
        echo "Starting Livox driver..."
        ros2 launch livox_ros_driver2 msg_MID360_launch.py &
        DRIVER_PID=$!
        
        echo "Waiting 5 seconds for driver to start..."
        sleep 5
        
        echo ""
        echo "=== ROS2 Node List ==="
        ros2 node list
        
        echo ""
        echo "=== ROS2 Topic List ==="
        ros2 topic list
        
        echo ""
        echo "=== ROS2 Topic Info ==="
        for topic in /livox/lidar /livox/imu; do
            if ros2 topic list | grep -q "$topic"; then
                echo "Topic $topic exists!"
                ros2 topic info "$topic"
            else
                echo "Topic $topic NOT found"
            fi
        done
        
        echo ""
        echo "=== ROS2 Topic HZ (5 second sample) ==="
        for topic in /livox/lidar /livox/imu; do
            if ros2 topic list | grep -q "$topic"; then echo "Checking Hz for $topic..."; timeout 5 ros2 topic hz "$topic" || echo "No messages on $topic"; fi
        done
        
        echo ""
        echo "Killing driver..."
        kill $DRIVER_PID 2>/dev/null || true
      '
fi