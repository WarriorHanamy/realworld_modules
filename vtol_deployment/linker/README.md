# linker

`linker` contains real-world backend integration utilities used by the VTOL
stack during hardware deployment.

Each sub-module connects a physical device or runtime backend into the ROS 2
namespace so that upper-layer logic can consume sensor and flight data without
depending on simulator-specific providers.

In the `vtol_deployment` architecture, `linker` is the layer that replaces the
simulation backend when moving from simulation-first development to real-world
operation. It complements `../vtol_interface/`, rather than replacing the
upper-layer application logic defined there.

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
