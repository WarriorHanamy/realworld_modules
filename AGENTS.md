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

- `run_scripts/` holds entry scripts for the Jetson device, host tools, and shared utilities.
- **Preferred entry-script pattern**: `run-{platform}-{mode}-{feature}.sh` (platform: `jetson` or `host`, mode: `debug` or `prod`)
- **Utility patterns observed**:
  - `host-{action}-{feature}.sh` — host-side ops scripts (e.g., `host-sync-policies.sh`)
  - `jetson-{action}-{feature}.sh` — Jetson-side ops scripts (e.g., `jetson-check-cuda-status.sh`)
  - `host-kill-all-containers.sh`, `host-restart-syncthing.sh` — host utility scripts
- **Orchestration scripts** (e.g., `run-jetson-prod-stack.sh`) may manage multiple services and therefore use a broader naming scope.
- Prefer `tmux_utils.sh` for process lifecycle management when orchestrating multiple services.

## ROS2 Workspace Convention

- **Rule**: ROS2 Docker run scripts must treat `/home/ros/ros2_ws` as the canonical in-container workspace path.
- Use `/home/ros/ros2_ws/install/setup.bash` when sourcing the built ROS2 workspace.
- Use `/home/ros/ros2_ws/src` for source mounts when a run script bind-mounts ROS2 packages into a container.
- Do not introduce new `/root/ros2_ws` or `/root/px4_connector_ws` assumptions in `run_scripts/`.

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

## Debug Topic Naming Convention

**Rule**: Point cloud topics exported for debug or multi-machine monitoring must use the `/debug/`
namespace and preserve the source topic suffix.

- Keep the local-critical topics unchanged for the algorithm path.
- Do not expose raw local-critical point cloud topics directly as the remote debug contract.
- Publish mirrored or throttled debug point clouds under `/debug/...`.

Examples:

- `/cloud_registered` -> `/debug/cloud_registered`
- `/cloud_registered_body` -> `/debug/cloud_registered_body`
- `/cloud_effected` -> `/debug/cloud_effected`
- `/livox/lidar` debug mirror -> `/debug/livox/lidar`
- `/livox/lidar` throttled debug mirror -> `/debug/livox/lidar_throttled`

## ROS2 Source Convention in Docker Scripts

**Rule**: The `set +u`/`set -u` wrapper is only needed for `docker run` (new container).
For `docker exec` (attaching to existing container), use `&&` chaining directly.

```bash
# docker run - new container, needs set +u/set -u
docker run --rm -it IMAGE \
  bash -c 'set +u; source /opt/ros/humble/setup.bash; set -u; exec bash'

# docker exec - existing container, use && chaining
docker exec -it CONTAINER \
  bash -c 'source /opt/ros/humble/setup.bash && source /root/ws/install/setup.bash && exec bash'
```
