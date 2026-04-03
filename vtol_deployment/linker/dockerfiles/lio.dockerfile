FROM ros:humble-ros-base

ARG UBUNTU_PORTS_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
ARG ROS_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu

RUN sed -i "s|http://ports.ubuntu.com/ubuntu-ports|${UBUNTU_PORTS_MIRROR}|g" /etc/apt/sources.list && \
    sed -i "s|http://packages.ros.org/ros2/ubuntu|${ROS_MIRROR}|g" /etc/apt/sources.list.d/ros2.sources && \
    sed -i "s|Types: deb deb-src|Types: deb|g" /etc/apt/sources.list.d/ros2.sources && \
    cat /etc/apt/sources.list

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=humble
ENV WS_DIR=/root/ros2_ws
ENV OPENSSL_ROOT_DIR=/usr
ENV OPENSSL_CRYPTO_LIBRARY=/usr/lib/aarch64-linux-gnu/libcrypto.so
ENV OPENSSL_SSL_LIBRARY=/usr/lib/aarch64-linux-gnu/libssl.so
ENV CMAKE_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu
ENV CMAKE_INCLUDE_PATH=/usr/include:/usr/include/aarch64-linux-gnu

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    wget \
    python3-rosdep \
    libeigen3-dev \
    libflann-dev \
    libssl-dev \
    libpcl-dev \
    ros-humble-pcl-ros \
    ros-humble-pcl-conversions \
    ros-humble-tf2 \
    ros-humble-tf2-ros \
    ros-humble-tf2-sensor-msgs \
    ros-humble-tf2-geometry-msgs \
    ros-humble-tf2-eigen \
    ros-humble-eigen3-cmake-module && \
    rm -rf /var/lib/apt/lists/*

RUN rosdep init || echo "rosdep already initialized" && \
    rosdep update || rosdep update || true

RUN test -f ${OPENSSL_CRYPTO_LIBRARY} && test -f ${OPENSSL_SSL_LIBRARY}

WORKDIR ${WS_DIR}/src

COPY vtol_deployment/linker/lidar_connector/Livox-SDK2 /tmp/Livox-SDK2
RUN cd /tmp/Livox-SDK2 && \
    mkdir -p build && cd build && \
    cmake .. && make -j$(nproc) && make install && \
    ldconfig && \
    rm -rf /tmp/Livox-SDK2

COPY vtol_deployment/linker/lidar_connector/livox_ros_driver2 ./livox_ros_driver2
COPY vtol_deployment/linker/lidar_connector/FAST_LIO_ROS2 ./FAST_LIO_ROS2

WORKDIR ${WS_DIR}
SHELL ["/bin/bash", "-c"]

ENV LD_LIBRARY_PATH=/usr/local/lib

RUN rm -rf ${WS_DIR}/build ${WS_DIR}/install ${WS_DIR}/log && \
    source /opt/ros/humble/setup.bash && \
    colcon build \
    --packages-select livox_ros_driver2 fast_lio \
    --cmake-args -DHUMBLE_ROS=ON -DOPENSSL_ROOT_DIR=${OPENSSL_ROOT_DIR} -DOPENSSL_CRYPTO_LIBRARY=${OPENSSL_CRYPTO_LIBRARY} -DOPENSSL_SSL_LIBRARY=${OPENSSL_SSL_LIBRARY} -DCMAKE_LIBRARY_PATH=${CMAKE_LIBRARY_PATH} -DCMAKE_INCLUDE_PATH=${CMAKE_INCLUDE_PATH} \
    --parallel-workers 4

COPY vtol_deployment/linker/dockerfiles/ros_entrypoint.sh /ros_entrypoint.sh
RUN chmod +x /ros_entrypoint.sh

CMD ["ros2", "launch", "fast_lio", "mapping.launch.py", "config_file:=mid360.yaml", "rviz:=false"]

ENTRYPOINT ["/ros_entrypoint.sh"]
