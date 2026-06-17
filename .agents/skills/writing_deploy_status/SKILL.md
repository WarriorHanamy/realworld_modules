# writing-deploy-status

## Format

`STATUS.md` at repo root: append-only timeline of device deployments.

```markdown
## 2026-06-10 14:09

| Field            | Value                                       |
| ---------------- | ------------------------------------------- |
| **Commit**       | `527cf57` (`main`)                          |
| **Deploy**       | `uv run integration sync`                  |
| **Launch**       | `run-jetson-prod-all.sh` on `nv`            |
| **Topics**       | /Odometry: normal (10 Hz) /px4/imu: normal (100 Hz) |
| **Nodes**        | vtol-lio: running | vtol-px4-connector: running     |
| **Hardware**     | MID360: ok | FCU: ok                       |
| **Notes**        | —                                           |
```

## Focus

Three axes before writing:

| Axis | Meaning | Verification |
|------|---------|-------------|
| Identity | What code is running | `ssh nv@192.168.55.1 'cd /home/nv/realworld_modules && git log -1 --oneline'` |
| Liveness | Containers up and nodes running | `ssh nv@192.168.55.1 'docker ps --format "table {{.Names}}\t{{.Status}}"'` |
| Health | Topics publishing, hardware connected | `ssh nv@192.168.55.1 'docker exec vtol-lio bash -c \"source /opt/ros/humble/setup.bash && ros2 topic hz /Odometry\"'` |

**Never** record without remote verification.

## Inference from Code

1. Read `run-jetson-prod-all.sh` to find all containers.
2. Map each container to its hardware dependency via subscribed topics.
3. From the launch analysis:
   - `vtol-lio` runs Livox driver + FAST-LIO2. `/livox/imu` publishes → MID360 is OK.
   - `vtol-px4-connector` runs MicroXRCEAgent + px4_connector. `/px4/imu` publishes → FCU (PX4) connected via uxrce_dds.
4. Verify: `ros2 topic hz /livox/imu` for LiDAR, `ros2 topic hz /px4/imu` for FCU.

## Known Issues

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| `/livox/imu` missing | MID360 unpowered / driver crashed | `docker logs vtol-lio` check livox_ros_driver2 |
| `/px4/imu` missing | FCU unpowered / uxrce_dds Agent crashed | `docker logs vtol-px4-connector` check Agent |
| `/Odometry` missing | FAST-LIO2 crashed / no LiDAR input | `docker logs vtol-lio` check laserMapping |
| `/Odometry` frozen | Feature-sparse environment | Check count in log; tune yaml params |
| commit mismatch | Forgot `uv run integration sync` | Re-deploy |

## When to Update

- After every `uv run integration sync` or `uv run integration full`
- After any manual change on device (launch args, params, file edits)
- After hardware change (LiDAR replacement, FCU firmware update)
- When a known anomaly appears or clears

## Pattern Reference

Follows: systemd unit status (active/inactive/failed), Kubernetes probes
(liveness + health + hardware), GitOps reconciliation (running vs synced commit).
