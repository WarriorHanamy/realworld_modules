# SPDX-FileCopyrightText: OpenCode
# SPDX-License-Identifier: MIT
"""
PX4 connector launch file.

Reference topology:
  PX4 FMU -> MicroXRCEAgent -> px4_connector -> /px4/imu (sensor_msgs/Imu)
  /Odometry -> px4_connector -> /fmu/in/vehicle_visual_odometry

Run inside the PX4 connector container (vtol/px4-connector-jetson):
  ros2 launch /home/ros/bringup/launch/px4_connector.launch.py
"""

import launch
from launch.actions import (
    DeclareLaunchArgument,
    ExecuteProcess,
    LogInfo,
)
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    output_topic = LaunchConfiguration("output_topic", default="/px4/imu")
    output_mode = LaunchConfiguration("output_mode", default="topic")
    micro_xrce_device = LaunchConfiguration("micro_xrce_device", default="/dev/ttyTHS1")
    micro_xrce_baudrate = LaunchConfiguration("micro_xrce_baudrate", default="921600")

    topic_cmd = [
        "bash",
        "-c",
        "source /opt/ros/humble/setup.bash && "
        "source /home/ros/ros2_ws/install/setup.bash && "
        "ros2 launch px4_connector px4_connector_topic.launch.py "
        f"output_topic:={output_topic}",
    ]

    return launch.LaunchDescription(
        [
            DeclareLaunchArgument("output_topic", default_value="/px4/imu"),
            DeclareLaunchArgument("output_mode", default_value="topic"),
            LogInfo(
                msg=[
                    "Starting PX4 connector in ",
                    output_mode,
                    " mode (",
                    output_topic,
                    ")",
                ]
            ),
            ExecuteProcess(
                cmd=[
                    "MicroXRCEAgent",
                    "serial",
                    "--dev",
                    micro_xrce_device,
                    "-b",
                    micro_xrce_baudrate,
                ],
                name="micro_xrce_agent",
                output="screen",
            ),
            ExecuteProcess(
                cmd=["bash", "-c", "sleep 3"],
                name="wait_agent",
                output="screen",
            ),
            ExecuteProcess(cmd=topic_cmd, name="px4_connector", output="screen"),
        ]
    )
