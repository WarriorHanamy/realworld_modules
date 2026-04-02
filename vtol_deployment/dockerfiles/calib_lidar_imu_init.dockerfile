FROM ros:noetic-ros-base

ARG UBUNTU_PORTS_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
ARG ROS_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu

RUN sed -i "s|http://ports.ubuntu.com/ubuntu-ports|${UBUNTU_PORTS_MIRROR}|g" /etc/apt/sources.list

ENV DEBIAN_FRONTEND=noninteractive
ENV WS_DIR=/root/catkin_ws

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    wget \
    python3-pip \
    python3-tk \
    libeigen3-dev \
    libpcl-dev \
    libatlas-base-dev \
    libgoogle-glog-dev \
    libsuitesparse-dev \
    libglew-dev \
    ros-noetic-pcl-ros \
    ros-noetic-pcl-conversions \
    ros-noetic-eigen-conversions \
    ros-noetic-tf \
    ros-noetic-rviz

RUN pip3 install --no-cache-dir matplotlib

RUN cd /tmp && \
    wget -q https://github.com/ceres-solver/ceres-solver/archive/refs/tags/2.0.0.tar.gz && \
    tar zxf 2.0.0.tar.gz && \
    mkdir -p ceres-solver-2.0.0/build && \
    cd ceres-solver-2.0.0/build && \
    cmake -DCMAKE_BUILD_TYPE=Release .. && \
    make -j1 && make install && \
    ldconfig && \
    rm -rf /tmp/2.0.0.tar.gz /tmp/ceres-solver-2.0.0

WORKDIR ${WS_DIR}/src

COPY calibration/LiDAR_IMU_Init ./LiDAR_IMU_Init


RUN cd /tmp && \
    wget -q https://github.com/Livox-SDK/livox_ros_driver/archive/refs/tags/v2.6.0.tar.gz && \
    tar zxf v2.6.0.tar.gz && \
    mv livox_ros_driver-2.6.0 ${WS_DIR}/src/livox_ros_driver && \
    rm -rf /tmp/v2.6.0.tar.gz

WORKDIR ${WS_DIR}
SHELL ["/bin/bash", "-c"]

RUN --mount=type=cache,target=${WS_DIR}/build \
    --mount=type=cache,target=${WS_DIR}/devel \
    source /opt/ros/noetic/setup.bash && \
    catkin_make -j2

COPY vtol_deployment/dockerfiles/calib_entrypoint.sh /calib_entrypoint.sh
RUN chmod +x /calib_entrypoint.sh

ENTRYPOINT ["/calib_entrypoint.sh"]
CMD ["bash"]
