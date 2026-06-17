# SPDX-FileCopyrightText: OpenCode
# SPDX-License-Identifier: MIT

import launch
from launch.actions import ExecuteProcess, LogInfo
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    ros_domain_id = LaunchConfiguration("ros_domain_id", default="30")

    return launch.LaunchDescription(
        [
            LogInfo(msg=["=== Bringup Monitor: LIO Pipeline ==="]),
            LogInfo(msg=[f"ROS_DOMAIN_ID={ros_domain_id}"]),
            ExecuteProcess(
                cmd=["bash", "/home/ros/bringup/scripts/monitor.sh"],
                name="lio_monitor",
                output="screen",
            ),
        ]
    )
