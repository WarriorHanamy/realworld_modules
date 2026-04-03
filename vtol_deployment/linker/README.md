# linker

Hardware-to-ROS2 bridge modules. Each sub-module connects a physical device to
the ROS2 namespace so that downstream nodes can consume sensor and flight data
without worrying about driver details.

## Sub-modules

### lidar_connector

Bridges the hardware LiDAR sensor into the ROS2 space.

- Publishes raw point cloud topics via `livox_ros_driver2`.
- As an exception, also provides **LIO** (Lidar-Inertial Odometry) functionality
  through `FAST_LIO_ROS2`, producing `/Odometry` output.

### px4_connector

Bridges the FMU (flight management unit) hardware into the ROS2 space.

- Runs `Micro-XRCE-DDS-Agent` for PX4 DDS communication.
- Subscribes to `/Odometry` and publishes
  `/fmu/in/vehicle_visual_odometry` (with ENU/FLU to NED/FRD transform).

### calibration

Auxiliary utilities for sensor calibration.

- LiDAR-IMU extrinsic calibration using `LiDAR_IMU_Init`.
- Packaged as a one-shot Docker container: play a rosbag, get calibration
  results.
