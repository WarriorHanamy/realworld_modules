ARG BASE_IMAGE=ros:noetic-ros-base
ARG UBUNTU_PORTS_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
ARG CERES_VERSION=2.0.0
ARG LIVOX_DRIVER_VERSION=2.6.0
ARG CERES_CXX_FLAGS=-O0 -g0 -fno-inline

FROM ${BASE_IMAGE} AS ceres-builder

ARG UBUNTU_PORTS_MIRROR
ARG CERES_VERSION
ARG CERES_CXX_FLAGS

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i "s|http://ports.ubuntu.com/ubuntu-ports|${UBUNTU_PORTS_MIRROR}|g" /etc/apt/sources.list

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    wget \
    libeigen3-dev \
    libgoogle-glog-dev \
    libgflags-dev

RUN cd /tmp && \
    wget -q "https://github.com/ceres-solver/ceres-solver/archive/refs/tags/${CERES_VERSION}.tar.gz" && \
    tar zxf "${CERES_VERSION}.tar.gz" && \
    mkdir -p "ceres-solver-${CERES_VERSION}/build" && \
    cd "ceres-solver-${CERES_VERSION}/build" && \
    cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/ceres \
    -DCMAKE_CXX_FLAGS=${CERES_CXX_FLAGS} \
    -DCMAKE_CXX_FLAGS_RELEASE=${CERES_CXX_FLAGS} \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DSCHUR_SPECIALIZATIONS=OFF \
    -DSUITESPARSE=OFF \
    -DCXSPARSE=OFF \
    -DLAPACK=OFF \
    -DEIGENSPARSE=ON \
    -DCUSTOM_BLAS=ON \
    -DMINIGLOG=OFF \
    -DGFLAGS=ON \
    -DCERES_THREADING_MODEL=NO_THREADS \
    .. && \
    make -j1 && \
    make install && \
    rm -rf "/tmp/${CERES_VERSION}.tar.gz" "/tmp/ceres-solver-${CERES_VERSION}"

FROM ${BASE_IMAGE} AS pcl-builder

ARG UBUNTU_PORTS_MIRROR

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i "s|http://ports.ubuntu.com/ubuntu-ports|${UBUNTU_PORTS_MIRROR}|g" /etc/apt/sources.list

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    wget \
    python3-dev \
    python3-pip \
    libeigen3-dev \
    libgoogle-glog-dev \
    libgflags-dev

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get install -y --no-install-recommends --fix-missing \
    ros-noetic-tf \
    ros-noetic-eigen-conversions

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get install -y --no-install-recommends --fix-missing \
    ros-noetic-pcl-ros \
    ros-noetic-pcl-conversions \
    libpcl-dev \
    ros-noetic-ddynamic-reconfigure

FROM pcl-builder AS final

ARG LIVOX_DRIVER_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV WS_DIR=/root/catkin_ws
ENV Ceres_DIR=/opt/ceres/lib/cmake/Ceres
ENV CMAKE_PREFIX_PATH=/opt/ceres
ENV LD_LIBRARY_PATH=/opt/ceres/lib

COPY --from=ceres-builder /opt/ceres /opt/ceres

RUN pip3 install --no-cache-dir matplotlib

WORKDIR ${WS_DIR}/src

COPY vtol_deployment/linker/calibration/LiDAR_IMU_Init ./LiDAR_IMU_Init

RUN cd /tmp && \
    wget -q "https://github.com/Livox-SDK/livox_ros_driver/archive/refs/tags/v${LIVOX_DRIVER_VERSION}.tar.gz" && \
    tar zxf "v${LIVOX_DRIVER_VERSION}.tar.gz" && \
    mv "livox_ros_driver-${LIVOX_DRIVER_VERSION}" "${WS_DIR}/src/livox_ros_driver" && \
    rm -rf "/tmp/v${LIVOX_DRIVER_VERSION}.tar.gz"

WORKDIR ${WS_DIR}
SHELL ["/bin/bash", "-c"]

RUN sed -i '/^target_link_libraries(li_init/i add_dependencies(li_init ${${PROJECT_NAME}_EXPORTED_TARGETS} ${catkin_EXPORTED_TARGETS})' \
    ${WS_DIR}/src/LiDAR_IMU_Init/CMakeLists.txt && \
    source /opt/ros/noetic/setup.bash && \
    catkin_make -j1

RUN mkdir -p /data ${WS_DIR}/src/LiDAR_IMU_Init/result

COPY vtol_deployment/linker/calibration/dockerfiles/calib_entrypoint.sh /calib_entrypoint.sh
RUN chmod +x /calib_entrypoint.sh

COPY vtol_deployment/scripts/calib_run.sh /usr/local/bin/calib_run.sh
RUN chmod +x /usr/local/bin/calib_run.sh

ENTRYPOINT ["/calib_entrypoint.sh"]
CMD ["bash"]
