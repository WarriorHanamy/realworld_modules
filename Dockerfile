# =============================================================
# Bringup assembly image
#
# Lightweight ROS2 image that packages the bringup/ directory
# (launch files, configs, entrypoints, monitoring scripts)
# for LIO pipeline verification and system-level orchestration.
#
# Build:
#   make docker-build-bringup-jetson
#
# Run (on device, after service containers are up):
#   docker run --rm --net=host --ipc=host \
#     -e ROS_DOMAIN_ID=30 \
#     vtol/bringup-jetson:latest \
#     bash /home/ros/bringup/scripts/monitor.sh
# =============================================================

ARG BASE_IMAGE=vtol/l4t-ros2-base-jetson:latest
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-c"]

ENV ROS_DISTRO=humble
ENV WS_DIR=/home/ros/ros2_ws

COPY bringup/ /home/ros/bringup/

WORKDIR ${WS_DIR}
