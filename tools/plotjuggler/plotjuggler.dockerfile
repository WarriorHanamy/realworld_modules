FROM ros:humble-ros-base

ARG UBUNTU_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu
RUN sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" /etc/apt/sources.list

ENV DEBIAN_FRONTEND=noninteractive
ENV WS_DIR=/root/ros2_ws

ARG JETSON_BAGS=/root/jetson_bags/
ENV JETSON_BAGS=${JETSON_BAGS}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-humble-plotjuggler-ros

COPY px4_msgs ${WS_DIR}/src/px4_msgs
COPY px4_msgs_overlay/CMakeLists.txt ${WS_DIR}/src/px4_msgs/CMakeLists.txt
COPY px4_msgs_overlay/package.xml ${WS_DIR}/src/px4_msgs/package.xml

SHELL ["/bin/bash", "-c"]
RUN --mount=type=cache,target=${WS_DIR}/build \
    --mount=type=cache,target=${WS_DIR}/log \
    source /opt/ros/humble/setup.bash && \
    cd ${WS_DIR} && \
    colcon build --packages-select px4_msgs --symlink-install

COPY ros_entrypoint.sh /ros_entrypoint.sh
RUN chmod +x /ros_entrypoint.sh

VOLUME ["${JETSON_BAGS}"]

ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["ros2", "run", "plotjuggler", "plotjuggler"]
