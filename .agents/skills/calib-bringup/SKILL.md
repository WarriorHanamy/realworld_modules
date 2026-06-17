# calib-bringup

Diagnose and verify LiDAR-IMU extrinsic calibration (`vtol/calib-lidar-imu-init-jetson`).

## When to calibrate

- First-time hardware bringup (new drone)
- After LiDAR or IMU replacement
- After mechanical collision that may have shifted sensors
- Map quality degradation (drift, double walls)

## Container Health

```bash
ssh nv@192.168.55.1 "docker ps --filter name=vtol-calib --format 'table {{.Names}}\t{{.Status}}'"
```

## Prerequisites

Before running calibration, verify:

```bash
# LiDAR data
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && timeout 2 ros2 topic echo /livox/lidar --once'"

# IMU data (from PX4)
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && timeout 2 ros2 topic echo /px4/imu --once'"

# IMU data (from LiDAR)
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && timeout 2 ros2 topic echo /livox/imu --once'"
```

Both `/livox/lidar` and `/livox/imu` (or `/px4/imu`) must publish data.

## Calibration container

The calibration tool (LI-Init) subscribes to LiDAR + IMU topics and estimates
the extrinsic transform between them.

### Start calibration

```bash
ssh nv@192.168.55.1 "docker start vtol-calib && docker logs -f vtol-calib"
```

### Monitor progress

```bash
ssh nv@192.168.55.1 "docker exec vtol-calib bash -c 'source /opt/ros/humble/setup.bash && ros2 topic echo /calib/status --once'"
```

Expected status: `INITIALIZING` → `COLLECTING` → `OPTIMIZING` → `CONVERGED`.

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|------|
| `No lidar data received` | LiDAR not running or wrong topic | Check `/livox/lidar` is publishing |
| `No imu data received` | IMU not running or wrong topic | Check `/livox/imu` or `/px4/imu` |
| `Calibration not converging` | Not enough motion during collection | Move the drone in figure-8 patterns |
| `Initial rotation estimate failed` | Insufficient initial excitation | Rotate drone 90° in each axis at start |
| `Container exits immediately` | Dependency (topic) not ready | Start LIO and px4-connector first |

## Verification

After calibration completes, check the result:

```bash
ssh nv@192.168.55.1 "docker logs vtol-calib | tail -20"
```

Look for:

```
[INFO] Extrinsic (LiDAR→IMU):
[INFO]   Rotation (quat):   [0.999, 0.003, -0.004, 0.001]
[INFO]   Translation (m):   [0.05, 0.00, -0.02]
[INFO]   Reprojection error: 0.032 (px)
```

## Updating extrinsics

Copy the calibrated values into the FAST-LIO2 config:

```yaml
# run_scripts/config/{model}.yaml
calibration:
    extrinsic_T: [0.05, 0.00, -0.02]
    extrinsic_R: [0.999, 0.003, -0.004, 0.001, ...]
```

## Key Files

| File | Role |
|------|------|
| `run_scripts/run-jetson-debug-calib-lidar-imu.sh` | Calibration bringup script |
| `run_scripts/config/fastlio_mid360.yaml` | Reference LIO config (extrinsics target) |
| `linker/` submodule | LI-Init calibration source |
