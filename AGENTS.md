# Project Agent Guidelines

## Remote Execution

This project uses Syncthing for bidirectional sync between host and Jetson device.
Use the remote execution wrappers instead of direct commands:


Device config: `sync/.env` (DEVICE_IP, DEVICE_USER, SSH_KEY, etc.)
