---
name: docker-rviz-debug
description: Debug Docker container RViz when connecting to remote Jetson ROS master. Covers mDNS, X11, ROS_HOSTNAME, GPU passthrough, YAML quoting, and PATH issues.
---

# docker-rviz-debug

## Purpose

When running `uv run viz yopo`, the Docker RViz container (`deploy.compose.rviz.yml`)
uses `osrf/ros:noetic-desktop-full` to connect to a remote Jetson ROS master. Six
non-obvious failure modes can prevent RViz from starting, connecting, or rendering.

## Checklist

### 1. mDNS — .local names don't resolve in container

| Symptom | Check | Fix |
|---|---|---|
| `WARN[0000] The "ROS_MASTER_URI" variable is not set.`<br>`rostopic list` timeout or empty | `docker exec <ctr> bash -c 'echo $ROS_MASTER_URI'` | Resolve hostname on host side before `docker compose up`, pass IP as env var |

```python
# c5pro/cli/viz.py:112-121
jetson_ip = REMOTE_HOST
compose_env = _env()
compose_env["ROS_MASTER_URI"] = f"http://{jetson_ip}:11311"
compose_env["JETSON_IP"] = jetson_ip
```

```yaml
# docker/deploy.compose.rviz.yml:21-22
extra_hosts:
  - "nv:${JETSON_IP}"
```

**Diagnostic:**
```bash
docker exec ros1-yopo-ros1-runtime-rviz \
  bash -c 'echo $ROS_MASTER_URI'
docker exec ros1-yopo-ros1-runtime-rviz \
  bash -c 'rostopic list 2>&1'
```

---

### 2. ROS_HOSTNAME=localhost blocks remote connections

| Symptom | Check | Fix |
|---|---|---|
| `ROS_HOSTNAME / ROS_IP is set to only allow local connections, so a requested connection to 'nv' is being rejected.` | `docker exec <ctr> bash -c 'echo $ROS_HOSTNAME'` | Remove `ROS_HOSTNAME` from compose environment |

```
# docker/deploy.compose.rviz.yml — DON'T set ROS_HOSTNAME
# Delete or comment out:
#   - "ROS_HOSTNAME=${ROS_HOSTNAME:-localhost}"
```

With `network_mode: host`, ROS auto-detects the network. `localhost` explicitly
prevents outbound connections to the Jetson.

---

### 3. X11 — root user not authorized

| Symptom | Check | Fix |
|---|---|---|
| `Invalid MIT-MAGIC-COOKIE-1 key`<br>`qt.qpa.xcb: could not connect to display` | `xhost` on host | Call `_authorize_docker_x11()` before `docker compose up` |

```python
# c5pro/cli/viz.py:123-124
_authorize_docker_x11("[c5pro]")
```

This runs `xhost +SI:localuser:root` to allow the container's root user.

---

### 4. rviz not found in PATH

| Symptom | Check | Fix |
|---|---|---|
| `exec: "rviz": executable file not found in $PATH` | `docker exec <ctr> which rviz` | Source ROS setup.bash before running rviz |

```python
# c5pro/cli/viz.py:180-189
subprocess.run([
    _docker(), "exec", "-it", container, "bash", "-c",
    "source /opt/ros/noetic/setup.bash && rviz -d /rviz_configs/yopo_debug.rviz",
])
```

`docker exec` creates a new process — it does NOT source the entrypoint's
environment.

---

### 5. YAML colon parsing in unquoted env values

| Symptom | Check | Fix |
|---|---|---|
| Env var in container is truncated (e.g. `ROS_MASTER_URI` blank) | `docker exec <ctr> bash -c 'echo $ROS_MASTER_URI'` | Quote all `environment:` values in compose |

```yaml
# docker/deploy.compose.rviz.yml — YES:
    - "ROS_MASTER_URI=${ROS_MASTER_URI:-http://192.168.55.1:11311}"
    - "NVIDIA_VISIBLE_DEVICES=all"
    - "DISPLAY=${DISPLAY:-}"

# — NO (unquoted, colon may break YAML parser):
    - ROS_MASTER_URI=${ROS_MASTER_URI:-http://192.168.55.1:11311}
```

---

### 6. NVIDIA GPU not available (llvmpipe fallback)

| Symptom | Check | Fix |
|---|---|---|
| `libGL error: failed to load driver: nvidia-drm`<br>OpenGL device: `llvmpipe` | `docker exec <ctr> bash -c 'glxinfo 2>/dev/null \| grep "OpenGL renderer"'` | Add `runtime: nvidia` + env vars |

```yaml
# docker/deploy.compose.rviz.yml:20,25-26
    runtime: nvidia
    environment:
      - "NVIDIA_VISIBLE_DEVICES=all"
      - "NVIDIA_DRIVER_CAPABILITIES=all"
```

Requires `nvidia-container-toolkit` installed on the host. For AMD/iGPU,
mount `/dev/dri:/dev/dri` instead.

**Verify GPU passthrough:**
```bash
docker exec ros1-yopo-ros1-runtime-rviz \
  bash -c 'nvidia-smi 2>/dev/null || echo "No nvidia-smi in container (non-NVIDIA image)"'
```

## Reference: Healthy State

A working `uv run viz yopo` produces no GL errors, no ROS_HOSTNAME warnings,
and `rostopic list` detects topics within 3-15 seconds.

## Related

| Resource | Link |
|---|---|
| AGENTS.md §5.6 | Docker rviz DNS diagnostic commands |
| `c5pro/cli/viz.py` | Python orchestrator |
| `docker/deploy.compose.rviz.yml` | Compose file |
| `deploy-side/tmux_scripts/host_yopo_debug_bringup.sh` | Shell equivalent |
