# Agent Skills Index

Assembly layer AI assistant skills for the VTOL Jetson production stack.
Loaded by the agent on-demand. All skills stay at this layer (not in submodules).

## Assembly Layer — root concerns

| Skill | Scope | Purpose |
|-------|-------|---------|
| `setup-device/` | Jetson bare-metal | Full device bringup — SSH, mDNS, eth0 static IP, WiFi lock, NTP, Livox SDK, uxrce_dds serial port |
| `docker-naming/` | convention | Image, container, tmux session, SSH host naming under `vtol/*` |
| `writing-tmux/` | `run_scripts/` | Tmux orchestration scripts — lifecycle, pane layout, health checks |
| `writing_deploy_status/` | `STATUS.md` | Append-only deployment journal — identity, liveness, health |
| `ci-cd/` | Docker lifecycle | 3-stage container pipeline (CI/test, CD/prod, debug), C++ build certification |
| `nv-network-proxy/` | host ↔ Jetson | Transparent proxy via nftables — TCP + DNS routing through host Clash |
| `mdns-host-discovery/` | network | mDNS/Avahi forward/reverse host discovery and troubleshooting |
| `jetson-device-docker-build/` | Jetson Docker | Native aarch64 Docker image builds on Jetson (L4T base, ROS2 Humble) |

## Container Skills — 1:1 with Docker containers

| Skill | Container | Purpose |
|-------|-----------|---------|
| `lidar-debug/` | `vtol/lio-jetson` | Livox MID360 3-layer diagnosis — network reachability, driver JSON config, SLAM message type |
| `lio-bringup/` | `vtol/lio-jetson` | FAST-LIO2 SLAM bringup — topic health, TF, point cloud output, LiDAR-IMU sync |
| `px4-bridge/` | `vtol/px4-connector-jetson` | uxrce_dds Agent serial diagnostics, px4_connector node (IMU sender, VO bridge) |
| `calib-bringup/` | `vtol/calib-lidar-imu-init-jetson` | LiDAR-IMU extrinsic calibration bringup and result verification |
| `docker-rviz-debug/` | `vtol/fastlio-debug-host` | Host-side Docker RViz — X11 passthrough, GPU, DDS multi-machine discovery |

## Middleware Skills — cross-cutting

| Skill | Concern | Purpose |
|-------|---------|---------|
| `fastdds-debug/` | FastDDS | Profile selection (local/debug), multi-machine participant discovery, port conflicts |
| `uxrce-dds-debug/` | Micro-XRCE-DDS | Agent serial link health, topic mapping drift, QoS mismatch, device-lost recovery |

## Generic Skills — project-agnostic

| Skill | Purpose |
|-------|---------|
| `ssh-target-setup/` | Passwordless SSH login + passwordless sudo (NOPASSWD) |
| `uml/` | PlantUML diagrams — class, sequence, deployment, state machine, component |
| `ros-debug-bringup/` | ROS2 bringup patterns — XML pitfalls, lazy imports, independent node verification |

## Per-skill layout

```
skills/<name>/
  SKILL.md          # Loaded by agent
  resource/         # Configs, scripts, reference docs (optional)
```

## Related

- `AGENTS.md` — root-level agent guidelines referencing this index.
- `run_scripts/` — execution scripts that skill diagnostics validate against.
