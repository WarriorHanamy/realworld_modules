This module bridges FAST-LIO odometry into PX4 visual odometry topics.

It owns:
- the ROS 2 odometry bridge package
- the Micro-XRCE-DDS-Agent runtime dependency

Current scope:
- subscribe to `/Odometry` (`nav_msgs/msg/Odometry`)
- transform ENU/FLU to NED/FRD
- publish `/fmu/in/vehicle_visual_odometry` (`px4_msgs/msg/VehicleOdometry`)
