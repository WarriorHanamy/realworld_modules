# lio-bringup

Diagnose FAST-LIO2 SLAM inside `vtol/lio-jetson`. Covers config alignment,
topic verification, and point cloud quality.

## Architecture

```
Livox driver ──/livox/lidar──▶ FAST-LIO2 ──/Odometry──▶ consumers
              ──/livox/imu───▶           ──/cloud_registered──▶ debug
```

## Container Health

```bash
ssh nv@192.168.55.1 "docker ps --filter name=vtol-lio --format 'table {{.Names}}\t{{.Status}}'"
```

## Config Alignment

### Config file

`run_scripts/config/{model}.yaml` loaded by FAST-LIO2 launch.

### Critical: lidar_type

```yaml
preprocess:
    lidar_type: 6   # sensor_msgs::PointCloud2
```

| Value | Expected msg type | Driver xfer_format |
|-------|------------------|-------------------|
| 1 | `livox_ros_driver::CustomMsg` | 1 |
| 6 | `sensor_msgs::PointCloud2` | 0 |

**Rule:** `lidar_type` must match `xfer_format` in the Livox driver launch.
Mismatch = subscriber gets zero points silently.

### Topic name alignment

```yaml
common:
    lid_topic: "/livox/lidar"   # must match driver output
    imu_topic: "/livox/imu"     # must match driver output
```

### LiDAR-IMU extrinsics

```yaml
calibration:
    # lidar to imu (quaternion + translation)
    extrinsic_T: [0.0, 0.0, 0.0]
    extrinsic_R: [1, 0, 0, 0, 1, 0, 0, 0, 1]
```

Wrong extrinsics cause distorted maps. Verify against actual sensor mount.

## Topic Verification

### Check LIO nodes

```bash
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && ros2 node list'"
```

Expected: `/laserMapping`, `/livox_ros_driver2_node`.

### Check LIO topics

```bash
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && ros2 topic list'"
```

Expected:
- `/livox/lidar` — raw point cloud from driver
- `/livox/imu` — IMU from driver
- `/Odometry` — FAST-LIO2 output (key frame, ~10 Hz)
- `/cloud_registered` — registered point cloud (~1 Hz)
- `/debug/cloud_registered` — mirrored debug topic (if enabled)

### Check topic rate

```bash
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && timeout 3 ros2 topic hz /Odometry 2>&1'"
```

Expected: `/Odometry` ~10 Hz, `/livox/lidar` ~10 Hz (MID360), `/livox/imu` ~100 Hz.

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `/Odometry` missing | FAST-LIO2 not receiving lidar or IMU | Check lidar_type, xfer_format, topic names |
| `/Odometry` publishes 0 Hz | No valid LiDAR features detected | Check environment (feature-sparse: blank wall, open sky) |
| `No point, skip this scan!` in log | `lidar_type=1` but driver publishes PointCloud2 | Set `lidar_type=6`, `xfer_format=0` |
| Map drifting | IMU not publishing or extrinsics wrong | Check `/livox/imu` rate; verify extrinsics |
| `/cloud_registered` not updating | Too many features or CPU overload | Check `docker stats vtol-lio` for CPU |
| High CPU (>80%) | FAST-LIO2 max iteration count too high | Tune `max_iteration` in yaml (default 3) |

## Isolation Test

Test FAST-LIO2 against rosbag replay (no hardware needed):

```bash
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c '
source /opt/ros/humble/setup.bash
timeout 5 ros2 topic echo /Odometry --once 2>/dev/null && echo \"LIO ACTIVE\" || echo \"LIO IDLE\"
'"
```

## Resource Constraints

Production run pins LIO to CPUs 2-5:

```bash
ssh nv@192.168.55.1 "docker inspect vtol-lio | jq -r '.[0].HostConfig.CpusetCpus'"
```

Expected: `"2-5"`.

## Key Files

| File | Role |
|------|------|
| `run_scripts/config/{model}.yaml` | FAST-LIO2 parameters |
| `run_scripts/config/fastlio_mid360.yaml` | Reference config |
| `linker/` submodule | FAST-LIO2 source |
