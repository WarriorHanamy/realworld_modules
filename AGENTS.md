# Project Agent Guidelines

## Remote Execution

This project uses Syncthing for bidirectional sync between host and Jetson device.
Use the remote execution wrappers instead of direct commands:

Device config: `sync_service/.env` (DEVICE_IP, DEVICE_USER, SSH_KEY, etc.)

## Network Convention

- **host**: 192.168.55.100 (development machine)
- **device**: 192.168.55.1 (Jetson device)

When referring to network operations, use these IP addresses consistently.

## Dependency Rules

### px4_msgs Dependency Separation

- `vtol_deployment/linker` must maintain its own `px4_msgs` submodule.
- Do NOT use `vtol_deployment/vtol_interface/src/px4_msgs` for linker builds.
- Each component (vtol_interface, linker) manages its own px4_msgs version.
- This ensures independent versioning and deployment of real-world components.
