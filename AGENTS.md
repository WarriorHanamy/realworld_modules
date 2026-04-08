# Project Agent Guidelines

## Remote Execution

This project uses Syncthing for bidirectional sync between host and Jetson device.
Use the remote execution wrappers instead of direct commands:

Device config: `sync_service/sync_env` (DEVICE_IP, DEVICE_USER, SSH_KEY, etc.)

## Repository Structure Convention

- Subfolders are developed independently.
- The repository root is an assembly layer for easy-to-use integration workflows.

## Makefile Convention

- Image name: `vtol/{service}-{platform}:latest` (platform: `jetson` or `host`)
- Build: `docker-build-{service}-jetson`
- Run: `docker-run-{service}-jetson`
- Shell (debug): `docker-run-{service}-jetson-shell`
- All `docker run` must include `--network host` and `--ipc host`
- Each directly runnable Jetson service must provide a `docker-run-{service}-jetson` example in its owning subfolder Makefile

## Run Scripts Convention

- `run_scripts/` holds entry scripts for the Jetson device.
- Filename: `run-{platform}-{mode}-{feature}.sh` (platform: `jetson` or `host`, mode: `debug` or `prod`)
- Each script handles one service.
- Prefer `tmux_utils.sh` for process lifecycle management when orchestrating multiple services.

## Discovery Rule

- When creating or updating `run_scripts/`, inspect the owning subfolder Makefile only.
- Prefer the `docker-run-{service}-jetson` target as the runtime example.
- Do not invent a root-level runtime shape that conflicts with the subfolder Makefile.

## Run Scripts Restriction

- When writing `run_scripts/`, you are **not allowed to change subfolder things** (code, configs, Dockerfiles, etc.).
- You **can read and rewrite** existing `run_scripts/` files only.
- If subfolder changes are needed, propose them separately for the subfolder owner.

## ROS2 Domain ID Convention

**Rule**: All ROS2 Docker containers must use `ROS_DOMAIN_ID=30` to ensure consistent domain isolation.

```bash
# Add to docker run commands:
-e ROS_DOMAIN_ID=30
```

## ROS2 Entrypoint Convention

**Rule**: In every Docker entrypoint script that sources ROS2 setup files, wrap all `source .../setup.bash`
calls between `set +u` and `set -u`.

```bash
#!/bin/bash
set -eo pipefail

# ROS2 setup.bash references unbound variables (e.g. AMENT_TRACE_SETUP_FILES).
# Temporarily disable nounset around sourcing to avoid "unbound variable" errors.
set +u
source /opt/ros/humble/setup.bash

WS_SETUP="${WS_DIR:-/root/ros2_ws}/install/setup.bash"
if [ -f "$WS_SETUP" ]; then
    source "$WS_SETUP"
fi
set -u

exec "$@"
```

Applies to ROS2 (humble, iron, jazzy, rolling) but **not** ROS1 (noetic), which does not have this issue.
