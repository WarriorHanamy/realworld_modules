# Project Agent Guidelines

## Remote Execution

This project uses Syncthing for bidirectional sync between host and Jetson device.
Use the remote execution wrappers instead of direct commands:

Device config: `sync_service/.env` (DEVICE_IP, DEVICE_USER, SSH_KEY, etc.)

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
- Filename: `run_{service}_{platform}.sh` (platform: `jetson` or `host`)
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
