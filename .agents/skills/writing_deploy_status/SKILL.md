---
name: writing-deploy-status
description: Use when maintaining STATUS.md, deploying to remote hardware, checking deployed state, or recording bringup health.
---

# writing-deploy-status

## Format

STATUS.md at repo root: append-only timeline of machine deployments. Each entry is a dated section:

```markdown
## 2026-06-10 14:09

| Field            | Value                                       |
| ---------------- | ------------------------------------------- |
| **Commit**       | `527cf57` (`main`)                          |
| **Deploy**       | `uv run integration sync`                  |
| **Launch**       | `roslaunch bringup bringup.launch` on `nv`  |
| **Topics**       | /Odometry: normal (100 Hz)                  |
| **Nodes**        | px4ctrl: running | laserMapping: running     |
| **Hardware**     | MID360: ok | FCU: ok                       |
| **Notes**        | —                                           |
```

## Focus

Three axes must be verified before writing any entry:

| Axis     | Meaning                                  | Verification                          |
| -------- | ---------------------------------------- | ------------------------------------- |
| Identity | What code is actually running            | `ssh nv@nv-V25.local 'cd /home/nv/V25-V25-ros1-yopo && git log -1 --oneline'` |
| Liveness | roslaunch alive and nodes up             | `ssh nv@nv-V25.local 'rosnode list'`     |
| Health   | Topics publishing, hardware connected    | `rostopic hz /livox/imu /Odometry`   |

**Never** record an entry without remote verification. A stale STATUS.md is worse than none.

## Inference from Code

Do not guess hardware status. Read the launch files to understand the dependency chain,
then verify only what the code actually uses.

1. Read `bringup.launch` and its includes to find every ROS node.
2. Map each node to its hardware dependency via its subscribed topics.
3. From the launch file analysis:
   - `msg_MID360s.launch` launches `livox_ros_driver2_node` (pkg `livox_ros_driver2`).
     It subscribes to **MID360** LiDAR on UDP port 56300/56400 and publishes `/livox/imu`,
     `/livox/lidar`. If `/livox/imu` publishes, **MID360** is ok.
   - `run_ctrl.launch` launches `px4ctrl_node` (pkg `px4ctrl`).
     It subscribes to `/mavros/state`, `/mavros/imu/data`, etc. If these topics publish,
     the **FCU (PX4)** is connected via MAVROS.
4. Verify on remote: `rostopic hz /livox/imu` for MID360,
   `rostopic echo /mavros/state -n1` for FCU.
5. Hardware field only tracks these two. Do not add sensors not found in the launch chain.

## Known Issues

| Symptom             | Likely cause                          | Action                                      |
| ------------------- | ------------------------------------- | ------------------------------------------- |
| `/livox/imu` missing| MID360 unpowered / livox_ros_driver2 crashed | `rosnode list` check livox_lidar_publisher2 |
| `/mavros/state` missing | FCU unpowered / MAVROS crashed / USB disconnect | `rosnode list | grep mavros`; `dmesg -T` for USB errors |
| `/Odometry` missing | FAST-LIO crashed / no LiDAR input      | `rosnode list` check laserMapping           |
| `/Odometry` frozen  | LiDAR feature-sparse environment       | Check feature count in log; mid360.yaml     |
| commit mismatch     | Forgot `uv run integration sync`      | Re-deploy                                   |

## When to Update

- After every `uv run integration sync` or `uv run integration full`
- After any manual change on remote (launch args, params, file edits)
- After hardware change (LiDAR replacement, FCU firmware update)
- When a known anomaly appears or clears

## Modern Practice References

The format follows three production patterns:

1. **systemd unit status** — active/inactive/failed per node, matching `rosnode ping` output
2. **Kubernetes probes** — liveness (is it running), health (is it publishing), hardware (are sensors connected)
3. **GitOps reconciliation** — the running commit vs the synced commit; notate when they differ
