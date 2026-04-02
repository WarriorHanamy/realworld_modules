FROM ros:humble-ros-base

ARG UBUNTU_PORTS_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
ARG ROS_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu

RUN sed -i "s|http://ports.ubuntu.com/ubuntu-ports|${UBUNTU_PORTS_MIRROR}|g" /etc/apt/sources.list && \
    cat /etc/apt/sources.list

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=humble
ENV WS_DIR=/root/ros2_ws

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    wget \
    python3-rosdep \
    libpcl-dev

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-humble-pcl-ros \
    ros-humble-pcl-conversions \
    ros-humble-tf2 \
    ros-humble-tf2-ros \
    ros-humble-tf2-sensor-msgs \
    ros-humble-tf2-geometry-msgs \
    ros-humble-tf2-eigen \
    ros-humble-eigen3-cmake-module

RUN rosdep init || echo "rosdep already initialized" && \
    rosdep update

WORKDIR ${WS_DIR}/src

COPY lio/livox_ros_driver2 ./livox_ros_driver2
RUN cd livox_ros_driver2 && \
    mv package_ROS2.xml package.xml && \
    sed -i '/LIVOX_INTERFACES_INCLUDE_DIRECTORIES/d' CMakeLists.txt

COPY lio/Livox-SDK2 /tmp/Livox-SDK2
RUN --mount=type=cache,target=/tmp/livox-sdk2-build \
    cd /tmp/Livox-SDK2 && \
    mkdir -p build && cd build && \
    cmake .. && make -j1 && make install && \
    ldconfig && \
    rm -rf /tmp/Livox-SDK2

COPY lio/FAST_LIO_ROS2 ./FAST_LIO_ROS2

WORKDIR ${WS_DIR}
SHELL ["/bin/bash", "-c"]

RUN --mount=type=cache,target=${WS_DIR}/build \
    --mount=type=cache,target=${WS_DIR}/log \
    source /opt/ros/humble/setup.bash && \
    colcon build \
    --packages-select livox_ros_driver2 fast_lio \
    --cmake-args -DROS_EDITION=ROS2 -DHUMBLE_ROS=ON \
    --symlink-install \
    --parallel-workers 4

COPY dockerfiles/ros_entrypoint.sh /ros_entrypoint.sh
RUN chmod +x /ros_entrypoint.sh

CMD ["ros2", "launch", "fast_lio", "mapping.launch.py", "config_file:=mid360.yaml", "rviz:=false"]

ENTRYPOINT ["/ros_entrypoint.sh"]
