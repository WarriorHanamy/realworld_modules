# px4-bridge

Diagnose the PX4 connector container (`vtol/px4-connector-jetson`), which bridges
Micro-XRCE-DDS Agent data into ROS2 topics consumed by SLAM and control nodes.

## Architecture

```
PX4 → uxrce_dds_Agent → FastDDS → px4_connector → ROS2 topics
                                     ├── ImuTopicSender         → /px4/imu
                                     ├── Px4VisualOdometryBridge → /px4/odom
                                     └── TimeSync                → /px4/timesync
```

## Container Health

### Check container is running

```bash
ssh nv@192.168.55.1 "docker ps --filter name=vtol-px4-connector --format 'table {{.Names}}\t{{.Status}}'"
```

### Check container resources

```bash
ssh nv@192.168.55.1 "docker stats vtol-px4-connector --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'"
```

Expected: CPU < 20%, memory stable.

### CPU pinning

Production run pins px4-connector to CPUs 6-7 (leaving 2-5 for LIO):

```bash
ssh nv@192.168.55.1 "docker inspect vtol-px4-connector | jq -r '.[0].HostConfig.CpusetCpus'"
```

Expected: `"6-7"`.

## Topic Verification

### Verify IMU sender

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && ros2 topic echo /px4/imu --once 2>/dev/null | head -10'"
```

Expected: valid IMU data (orientation, angular_velocity, linear_acceleration).

### Verify VO bridge

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && ros2 topic echo /px4/odom --once 2>/dev/null | head -10'"
```

Expected: valid Odometry message with pose + twist.

### Check topic rate

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && timeout 3 ros2 topic hz /px4/imu 2>&1'"
```

Expected: IMU ~100 Hz, odom ~50 Hz. If 0 Hz, Agent or FCU is not publishing.

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `No data on /px4/imu` | uxrce_dds Agent disconnected from FCU | Check serial link (see uxrce-dds-debug) |
| `Topic /px4/odom not found` | Px4VisualOdometryBridge not enabled in px4_connector config | Check connector launch params |
| `High latency on /px4/imu` | CPU contention (wrong cpuset) | Ensure `--cpuset-cpus 6-7` |
| `Topic exists but data frozen` | FCU stopped publishing | Check FCU status (LED, USB) |
| `Timestamp jumps` | Time sync not initialized | Wait 30s for time sync; check `/px4/timesync` |
| `ros2 topic list returns nothing` | Wrong ROS_DOMAIN_ID | Set `ROS_DOMAIN_ID=30` |

## Isolation Test

Verify the px4-connector independently (disconnect from LIO):

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c '
source /opt/ros/humble/setup.bash
echo \"=== Topics ===\"
ros2 topic list
echo \"=== IMU ===\"
timeout 2 ros2 topic echo /px4/imu --once 2>/dev/null
echo \"=== Odom ===\"
timeout 2 ros2 topic echo /px4/odom --once 2>/dev/null
'"
```

## Key Files

| File | Role |
|------|------|
| `run_scripts/config/px4-entrypoint.sh` | Container entrypoint (Agent + connector) |
| `run_scripts/config/uxrce-agent-local.refs` | Agent FastDDS profile |
| `linker/` submodule | px4_connector source code |
