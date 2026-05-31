# RealWorld Modules — Assembly Layer

Assembly-layer run scripts, config templates, and integration workflows for the VTOL Jetson production stack.
Subfolders (`linker/`, `debugger/`, `vtol_behavior_manager/`) are independent Git submodules; this root orchestrates them into pipelines.

## Run Scripts

| Script                                         | Platform | Purpose                                     |
| ---------------------------------------------- | -------- | ------------------------------------------- |
| `run_scripts/run-jetson-prod-all.sh`             | Jetson   | Full production stack (PX4 + LIO + BHT)     |
| `run_scripts/run-jetson-debug-linker.sh`         | Jetson   | PX4 connector + LIO debug                   |
| `run_scripts/run-jetson-debug-calib-lidar-imu.sh`| Jetson   | LiDAR-IMU calibration (live or from bag)    |
| `run_scripts/run-host-debug-lio-rviz.sh`         | Host     | RViz2 LIO debug via X11                     |
| `run_scripts/run-host-debug-px4-plotjuggler.sh`  | Host     | PlotJuggler debug via X11                   |
| `run_scripts/host-sync-policies.sh`              | Host     | Copy policy ONNX models to Jetson           |
| `run_scripts/host-kill-all-containers.sh`        | Host     | Emergency stop all containers               |
| `run_scripts/host-restart-syncthing.sh`          | Host     | Restart Syncthing on both host and Jetson    |
| `run_scripts/host-check-device-versions.sh`      | Host     | Probe Jetson JetPack/CUDA/PyTorch versions  |
| `run_scripts/host-check-jetson-wifi-subnet.sh`   | Host     | Verify host and Jetson WiFi on same subnet  |
| `run_scripts/jetson-check-cuda-status.sh`        | Jetson   | Compare container vs native CUDA versions   |

See [docs/architecture.md](docs/architecture.md) for PlantUML architecture diagrams and data-flow.

## Makefile Targets

### linker/ (sensor pipeline)

```
docker-build-base-jetson              docker-test-lio-jetson
docker-build-lio-jetson               docker-test-calib-jetson BAG=...
docker-build-px4-connector-jetson     docker-test-px4-connector-jetson
docker-build-calib-jetson             docker-test-px4-connector-jetson-shell
```

### vtol_behavior_manager/ (neural behavior)

```
sim                                   neural-infer-host
sim-kill                              neural-infer-device
docker-build-bht-amd                  neural-log-start-host
docker-build-bht-jetson               neural-log-finish-host
docker-offload-bhtBuildTask           install-host
sync-policies-host
```

### debugger/ (host visualization)

```
docker-build-plotjuggler      docker-run-plotjuggler
docker-build-fastlio-debug    docker-run-fastlio-debug
docker-build-all
```

## Quick Start

```bash
# 1. Configure device connection
cp sync_service/sync_env.example sync_service/sync_env
# edit DEVICE_IP, DEVICE_USER, SSH_KEY

# 2. Setup Jetson (SSH key, sudo, Syncthing, UFW)
sync_service/entrypoint.sh setup

# 3. Build images (on host, builds natively on Jetson via SSH)
cd linker && make docker-build-base-jetson && make docker-build-px4-connector-jetson && make docker-build-lio-jetson
cd ../vtol_behavior_manager && make docker-build-bht-jetson

# 4. Run full production stack
./run_scripts/run-jetson-prod-all.sh
```

## Key Files

| Path                                    | Purpose                            |
| --------------------------------------- | ---------------------------------- |
| `run_scripts/config/fastdds-local.xml`    | FastDDS profile (production)       |
| `run_scripts/config/fastdds-debug.xml`    | FastDDS profile (multi-machine)    |
| `run_scripts/config/px4-entrypoint.sh`    | PX4 connector container entrypoint |
| `run_scripts/config/lio-entrypoint.sh`    | LIO container entrypoint            |
| `run_scripts/config/fastlio_mid360.yaml`  | FAST-LIO config template            |
| `run_scripts/config/livox_mid360.json`    | Livox MID-360 driver template       |
| `run_scripts/tmux_utils.sh`              | Shared tmux orchestration          |
| `sync_service/sync_env`                   | Device IP/user/SSH key config      |

## Conventions

- Image names: `vtol/{service}-{platform}:latest` (platform: `jetson` or `host`)
- ROS domain: `ROS_DOMAIN_ID=30` everywhere
- All Docker containers: `--network=host --ipc=host`
- Build: natively on Jetson via SSH, no cross-compilation
- Coordinate frames: PX4 uses NED/FRD, training uses ENU/FLU; see `AGENTS.md` for full math conventions

## References

- [AGENTS.md](AGENTS.md) — Agent rules and naming conventions
- [docs/architecture.md](docs/architecture.md) — PlantUML architecture + data-flow diagrams
- [CODEBASE.md](CODEBASE.md) — Auto-generated codebase snapshot
- Linker submodule: [linker/AGENTS.md](linker/AGENTS.md)
- BHT submodule: [vtol_behavior_manager/README.md](vtol_behavior_manager/README.md), [vtol_behavior_manager/AGENTS.md](vtol_behavior_manager/AGENTS.md)
