FROM ros:humble-ros-core-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=humble
ENV WS_DIR=/root/px4_connector_ws

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    sudo \
    libeigen3-dev \
    python3-colcon-common-extensions \
    ros-humble-eigen3-cmake-module \
    ros-humble-nav-msgs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/agent
COPY vtol_deployment/linker/px4_connector/Micro-XRCE-DDS-Agent ./Micro-XRCE-DDS-Agent
RUN cd Micro-XRCE-DDS-Agent && \
    mkdir build && cd build && \
    cmake .. && \
    make -j2 && \
    make install && \
    cd / && rm -rf /tmp/agent

WORKDIR ${WS_DIR}/src

# Todo, the multiple places dependencies on px4_msgs.
COPY host/plotjuggler/px4_msgs ./px4_msgs
COPY host/plotjuggler/px4_msgs_overlay/CMakeLists.txt ./px4_msgs/CMakeLists.txt
COPY host/plotjuggler/px4_msgs_overlay/package.xml ./px4_msgs/package.xml
COPY vtol_deployment/linker/px4_connector/src/px4_odometry_bridge ./px4_odometry_bridge

WORKDIR ${WS_DIR}
SHELL ["/bin/bash", "-c"]

RUN rm -rf ${WS_DIR}/build ${WS_DIR}/install ${WS_DIR}/log && \
    source /opt/ros/humble/setup.bash && \
    colcon build \
    --packages-select px4_msgs px4_odometry_bridge \
    --parallel-workers 4

COPY vtol_deployment/linker/dockerfiles/px4_connector_entrypoint.sh /px4_connector_entrypoint.sh
RUN chmod +x /px4_connector_entrypoint.sh

ENTRYPOINT ["/px4_connector_entrypoint.sh"]
CMD ["ros2", "launch", "px4_odometry_bridge", "bridge.launch.py"]
