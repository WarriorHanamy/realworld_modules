# SPDX-FileCopyrightText: OpenCode
# SPDX-License-Identifier: MIT
"""
Linker (sensor assembly) bringup launch.

Wires PX4 connector + LIO into a unified sensor pipeline.
Run inside the bringup container for system-level orchestration:

  ros2 launch /home/ros/bringup/launch/linker.launch.py

Data flow:
  PX4 FMU -> PX4 connector -> /px4/imu (sensor_msgs/Imu)
                                |
  Livox LiDAR -> livox driver -> /livox/lidar (PointCloud2)
                                |------> FAST-LIO2 -> /Odometry (nav_msgs/Odometry)
                                                      |
                                                      +-> PX4 connector -> /fmu/in/vehicle_visual_odometry
"""

import launch
from launch.actions import (
    LogInfo,
    ExecuteProcess,
    RegisterEventHandler,
)
from launch.event_handlers import OnProcessStart


def generate_launch_description():
    return launch.LaunchDescription(
        [
            LogInfo(msg=["=" * 60]),
            LogInfo(msg=["Bringup: Linker (PX4 connector + LIO)"]),
            LogInfo(msg=["=" * 60]),
            LogInfo(msg=["Data flow:"]),
            LogInfo(msg=["  PX4 FMU -> PX4 connector -> /px4/imu"]),
            LogInfo(msg=["  Livox LiDAR -> livox driver -> /livox/lidar"]),
            LogInfo(msg=["  /px4/imu + /livox/lidar -> FAST-LIO -> /Odometry"]),
            LogInfo(
                msg=["  /Odometry -> PX4 connector -> /fmu/in/vehicle_visual_odometry"]
            ),
            LogInfo(msg=["=" * 60]),
            LogInfo(msg=["PX4 connector and LIO run in separate containers."]),
            LogInfo(msg=["Start them via run_scripts/:"]),
            LogInfo(msg=["  ./run_scripts/run-jetson-debug-linker.sh"]),
            LogInfo(msg=["  ./run_scripts/run-jetson-prod-all.sh"]),
            LogInfo(msg=[""]),
            LogInfo(msg=["Then verify topics from this bringup container:"]),
            LogInfo(msg=["  ros2 launch /home/ros/bringup/launch/monitor.launch.py"]),
        ]
    )
