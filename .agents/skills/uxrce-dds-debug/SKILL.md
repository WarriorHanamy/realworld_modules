# uxrce-dds-debug

Diagnose PX4-to-ROS2 bridge failures in the Micro-XRCE-DDS path:
Agent serial link, FastDDS participant discovery, topic mapping.

## Architecture

```
PX4 FCU ──serial──▶ MicroXRCEAgent ──DDS──▶ px4_connector ──ROS2 topic──▶ consumers
  /dev/ttyTHS1        UDP + SHM              ImuTopicSender
  921600 baud         port 14910-14940       Px4VisualOdometryBridge
```

## Layer 1 — Serial Link

### 1.1 Is the Agent running?

```bash
ssh nv@192.168.55.1 "docker ps --filter name=vtol-px4-connector --format '{{.Names}} {{.Status}}'"
```

Expected: `vtol-px4-connector-prod Up ...`

### 1.2 Is the serial device present?

```bash
ssh nv@192.168.55.1 "ls -l /dev/ttyTHS1"
```

Expected: character device, mode `crw-rw----`.

If missing: UART not enabled in device tree or TX2 pin conflict. Check:
```bash
ssh nv@192.168.55.1 "sudo ls /dev/ttyTH*"
```

### 1.3 Can the Agent open the port?

Check Agent logs:
```bash
ssh nv@192.168.55.1 "docker logs vtol-px4-connector 2>&1 | tail -20"
```

Expected output:
```
[Info] Agent Session Created
[Info] Client connected on session <id>
```

Errors to look for:

| Error | Cause | Fix |
|-------|-------|------|
| `serial: device not found` | Wrong device node | Set `MICRO_XRCE_DEVICE=/dev/ttyTHS1` |
| `serial: permission denied` | User not in dialout | `sudo usermod -aG dialout nv` (requires re-login) |
| `serial: no such file or directory` | UART not enabled | Check L4T device tree |
| `Agent crashed` | Memory / segfault | Check `dmesg -T` for OOM |

### 1.4 Is PX4 FCU sending data?

```bash
ssh nv@192.168.55.1 "sudo dd if=/dev/ttyTHS1 bs=1 count=100 2>/dev/null | hexdump -C"
```

Expected: non-zero binary data stream. If all zeroes, FCU is not connected.

### 1.5 Baud rate mismatch

The `MICRO_XRCE_BAUDRATE` env var must match the FCU's SERIAL_ param:

```bash
ssh nv@192.168.55.1 "docker inspect vtol-px4-connector | jq -r '.[0].Config.Env[] | select(startswith(\"MICRO_XRCE_BAUDRATE\"))'"
```

Expected: `MICRO_XRCE_BAUDRATE=921600`. Common mismatch: FCU defaults to 115200.

## Layer 2 — DDS Discovery

### 2.1 FastDDS profile

The Agent uses a FastDDS refs file specified by `MICRO_XRCE_REFS_FILE`:

```bash
ssh nv@192.168.55.1 "docker inspect vtol-px4-connector | jq -r '.[0].Config.Env[] | select(startswith(\"MICRO_XRCE_REFS_FILE\"))'"
```

Default: `/etc/uxrce/agent.refs` with UDP+SHM transport on `127.0.0.1`.

### 2.2 Is DDS participating?

Inside the container:

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && ros2 daemon status && ros2 topic list'"
```

Expected: at least `/fmu/out/*` topics visible.

If no topics: FastDDS discovery issue. Check `ROS_DOMAIN_ID=30` is set:

```bash
ssh nv@192.168.55.1 "docker inspect vtol-px4-connector | jq -r '.[0].Config.Env[] | select(startswith(\"ROS_DOMAIN_ID\"))'"
```

## Layer 3 — Topic Mapping

### 3.1 Verify expected topics

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && ros2 topic list'"
```

Expected topics (varies by config):
- `/fmu/out/vehicle_imu`
- `/fmu/out/vehicle_odometry`
- `/fmu/out/vehicle_attitude`
- `/fmu/out/timesync_status`

### 3.2 Verify IMU data rate

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && ros2 topic hz /fmu/out/vehicle_imu'"
```

Expected: ~100 Hz (imu) or ~50 Hz (odometry). If 0 Hz, FCU is not publishing.

### 3.3 QoS mismatch

Micro-XRCE-DDS uses `RMW_QOS_POLICY_RELIABILITY_BEST_EFFORT` by default.
If a consumer expects `RELIABLE`, topics won't arrive. Check consumer config:

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c 'source /opt/ros/humble/setup.bash && ros2 topic info /fmu/out/vehicle_imu'"
```

## Checklist

```
1. docker ps | grep vtol-px4-connector    ← container alive?
2. ls -l /dev/ttyTHS1                      ← serial device exists?
3. docker logs vtol-px4-connector | tail   ← Agent logs show "Client connected"?
4. dd if=/dev/ttyTHS1 bs=1 count=100       ← raw bytes from FCU?
5. docker exec ... ros2 topic list          ← DDS topics visible?
6. ros2 topic hz /fmu/out/vehicle_imu     ← IMU publishing?
```

## Key Files

| File | Role |
|------|------|
| `run_scripts/config/uxrce-agent-local.refs` | FastDDS XML profile for Agent |
| `run_scripts/config/px4-entrypoint.sh` | Container entrypoint (Agent + connector) |
| `run_scripts/run-jetson-prod-all.sh` | Production orchestration |
