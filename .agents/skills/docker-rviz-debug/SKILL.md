# docker-rviz-debug

When running `uv run viz lio`, the Docker RViz2 container uses
`osrf/ros:humble-desktop-full` to connect to a remote Jetson ROS2 system.
Six non-obvious failure modes.

## 1. mDNS — .local names don't resolve in container

| Symptom | Check | Fix |
|---------|-------|-----|
| `ROS_DISCOVERY_SERVER / ROS_AUTOMATIC_DISCOVERY_RANGE` unset; `ros2 topic list` empty | `docker exec <ctr> bash -c 'echo $ROS_DOMAIN_ID'` | Resolve IP on host before launch, pass as env var |

The compose file uses `extra_hosts` to map the Jetson hostname:

```yaml
extra_hosts:
  - "nv:${JETSON_IP}"
```

## 2. ROS_LOCALHOST_ONLY blocks remote discovery

| Symptom | Check | Fix |
|---------|-------|-----|
| Topics visible on Jetson but not in host container | `docker exec <ctr> bash -c 'echo $ROS_LOCALHOST_ONLY'` | Ensure `ROS_LOCALHOST_ONLY` is NOT set or set to `0` |

With `network_mode: host`, ROS2 auto-discovers interfaces. `ROS_LOCALHOST_ONLY=1`
restricts to loopback.

## 3. X11 — root user not authorized

| Symptom | Check | Fix |
|---------|-------|-----|
| `Invalid MIT-MAGIC-COOKIE-1 key` / `could not connect to display` | `xhost` on host | Call `xhost +SI:localuser:root` before `docker compose up` |

## 4. rviz2 not found in PATH

| Symptom | Check | Fix |
|---------|-------|-----|
| `exec: "rviz2": executable file not found` | `docker exec <ctr> which rviz2` | Source ROS2 setup.bash: `source /opt/ros/humble/setup.bash && rviz2` |

`docker exec` does NOT source the entrypoint environment.

## 5. YAML colon parsing in env values

| Symptom | Check | Fix |
|---------|-------|-----|
| Env var truncated in container | `docker exec <ctr> bash -c 'echo $FASTDDS_DEFAULT_PROFILES_FILE'` | Quote all `environment:` values in compose |

```yaml
# YES:
    - "FASTDDS_DEFAULT_PROFILES_FILE=/config/fastdds-debug.xml"
    - "DISPLAY=${DISPLAY:-}"

# NO (colon may break YAML parser):
    - FASTDDS_DEFAULT_PROFILES_FILE=/config/fastdds-debug.xml
```

## 6. NVIDIA GPU not available (llvmpipe fallback)

| Symptom | Check | Fix |
|---------|-------|-----|
| `libGL error: failed to load driver: nvidia-drm` | `docker exec <ctr> bash -c 'glxinfo 2>/dev/null \| grep "OpenGL renderer"'` | Add `runtime: nvidia` + `NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=all` |

Requires `nvidia-container-toolkit` on the host. Verify:

```bash
docker exec vtol-fastlio-debug-host bash -c 'nvidia-smi 2>/dev/null || echo "No nvidia-smi"'
```

## 7. FastDDS profile mismatch

| Symptom | Check | Fix |
|---------|-------|-----|
| Host container sees no Jetson topics | `docker exec <ctr> bash -c 'echo $FASTDDS_DEFAULT_PROFILES_FILE'` | Mount `fastdds-debug.xml` (not `fastdds-local.xml`) and set env var |

## Reference: Healthy State

A working `uv run viz lio` produces no GL errors, no DDS warnings, and
`ros2 topic list` detects Jetson topics within 5-10 seconds.

## Related

| Resource | Link |
|----------|------|
| AGENTS.md | ROS2 Docker source convention |
| `run_scripts/run-host-debug-lio-rviz.sh` | RViz host script |
| `run_scripts/config/fastdds-debug.xml` | Multi-machine DDS profile |
