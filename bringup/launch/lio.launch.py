# SPDX-FileCopyrightText: OpenCode
# SPDX-License-Identifier: MIT
"""
LIO pipeline launch file.

Run inside the LIO container (vtol/lio-jetson):
  ros2 launch /home/ros/bringup/launch/lio.launch.py

Topic flow:
  Livox LiDAR -> livox_ros_driver2 -> /livox/lidar, /livox/imu
  /livox/lidar + /px4/imu -> FAST-LIO -> /Odometry
"""

import launch
from launch.actions import DeclareLaunchArgument, ExecuteProcess, LogInfo
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    config_dir = LaunchConfiguration("config_dir", default="/home/ros/bringup/config")

    livox_cmd = [
        "bash",
        "-c",
        "source /opt/ros/humble/setup.bash && "
        "source /home/ros/ros2_ws/install/setup.bash && "
        "ros2 launch livox_ros_driver2 msg_MID360_launch.py",
    ]

    fastlio_cmd = [
        "bash",
        "-c",
        "source /opt/ros/humble/setup.bash && "
        "source /home/ros/ros2_ws/install/setup.bash && "
        "ros2 launch fast_lio mapping.launch.py config_file:=mid360.yaml rviz:=false",
    ]

    return launch.LaunchDescription(
        [
            DeclareLaunchArgument(
                "config_dir",
                default_value="/home/ros/bringup/config",
                description="Path to bringup config directory",
            ),
            LogInfo(msg=["Starting Livox driver..."]),
            ExecuteProcess(cmd=livox_cmd, name="livox_driver", output="screen"),
            LogInfo(msg=["Waiting 3s for driver initialization..."]),
            ExecuteProcess(
                cmd=[
                    "bash",
                    "-c",
                    "source /opt/ros/humble/setup.bash && "
                    "source /home/ros/ros2_ws/install/setup.bash && "
                    "echo 'Waiting for /livox/lidar and /px4/imu...' && "
                    "until ros2 topic list 2>/dev/null | grep -q '/livox/lidar'; do sleep 1; done && "
                    "until ros2 topic list 2>/dev/null | grep -q '/px4/imu'; do sleep 1; done && "
                    "echo 'All topics ready, starting FAST-LIO...'",
                ],
                name="topic_waiter",
                output="screen",
            ),
            LogInfo(msg=["Starting FAST-LIO mapping..."]),
            ExecuteProcess(cmd=fastlio_cmd, name="fastlio_mapping", output="screen"),
        ]
    )
