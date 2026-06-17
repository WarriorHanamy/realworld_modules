---
name: yopo-viz-bringup
description: End-to-end phased orchestration for YOPO LiDAR preprocessing and
  full-inference visualization. Supports two modes (preproc / full) with 4-phase
  bringup, per-step topic health checks, Docker RViz, and environment preparation.
  Use when launching, diagnosing, or automating the YOPO Docker RViz visualization
  workflow.
---

# yopo-viz-bringup

## Purpose

Launch a YOPO LiDAR debug visualization session from the devel machine in
**4 sequential phases**, each verified by ROS topic data availability. Two modes:

| Phase | **preproc** (default)                         | **full** (C5-lidar-yopo)                           |
|-------|------------------------------------------------|-----------------------------------------------------|
| 1     | LiDAR + faster-LIO SLAM                       | same                                                |
| 2     | EKF odometry fusion                           | same                                                |
| 3     | YOPO preprocessing pipeline (`yopo_lidar_preproc_node.py`) | YOPO full inference (`test_yopo_ros.py` + PyTorch) |
| 4     | Docker RViz via `yopo_debug.rviz`               | Docker RViz via `yopo_full_inference.rviz`          |

```
Phase 1  LiDAR + faster-LIO SLAM       → verify /cloud_registered_body
Phase 2  EKF odometry fusion           → verify /ekf/ekf_odom
Phase 3  YOPO pipeline                 → verify /yopo_net/perspective_depth (preproc) or /yopo_net/best_traj_visual (full)
Phase 4  Docker RViz (GPU, X11)        → close window to stop
```

## Quick start

```bash
# Pre-flight (one-time per machine)
bash .agents/skills/yopo-viz-bringup/check_env.sh

# Preproc mode (default, no ML deps)
bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh
bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --mode preproc

# Full inference mode (C5-lidar-yopo, needs PyTorch model on Jetson)
bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --mode full

# Rosbag replay (skip LiDAR+SLAM+EKF, only YOPO + RViz)
bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --bag /home/nv/ros1-yopo/data/scene.bag

# Skip pre-flight (already verified recently)
bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --skip-check
```

## Architecture

```
[Devel Machine (host)]                         [Jetson Orin NX]
                                                192.168.55.1
                                                 tmux "ros1-yopo-yopo-viz-debug"
  ┌─────────────────────┐
  │ Docker (rviz)        │                     ┌──────────────────────────┐
  │ osrf/ros:noetic      │◄── ROS (host net)── │ pane 0: lidar_launch.sh │
  │ network_mode: host   │                     │   → livox_ros_driver2   │
  │ GPU + X11            │                     │   → faster_lio          │
  │                      │                     ├──────────────────────────┤
  │ rostopic echo/hz     │◄── health check     │ pane 1: ekf_launch.sh   │
  │ (per phase poll)     │                     │   → ekf_quat_pose       │
  │                      │                     ├──────────────────────────┤
  │ preproc:             │                     │ pane 2 (varies by mode):│
  │   yopo_debug.rviz    │◄── ROS topics        │   preproc: yopo_preproc │
  │   11 image topics    │                     │   full:    test_yopo_ros │
  │ full:                │                     │           (PyTorch)     │
  │   yopo_full.rviz     │                     └──────────────────────────┘
  │   10 topics + trajs  │
  └─────────────────────┘
```

## Two modes

### `--mode preproc` (default)

Preprocess-only LiDAR pipeline. No ONNX / PyTorch / model file needed.

| Aspect          | Detail                                           |
|-----------------|--------------------------------------------------|
| YOPO script     | `yopo_lidar_preproc_node.py` via roslaunch       |
| Launch file     | `yopo_preprocess_debug.launch`                    |
| Dependencies    | numpy, opencv, scipy (no ML)                     |
| Phase 3 topic   | `/yopo_net/perspective_depth`                    |
| RViz config     | `yopo_debug.rviz` (5 image panels + 3D cloud)   |
| Jetson tmux     | New session via `lidar_launch.sh` shell-command |

### `--mode full` (C5-lidar-yopo)

Full YOPO network inference. Uses `test_yopo_ros.py` from the separate
`YOPO-C5Pro-Lidar` repo on the Jetson with a PyTorch model.

| Aspect          | Detail                                           |
|-----------------|--------------------------------------------------|
| YOPO script     | `test_yopo_ros.py` (python3, direct)             |
| Model format    | PyTorch `.pth` (not ONNX)                        |
| Model path      | `${YOPO_DIR}/YOPO/saved/YOPO_1/epoch50.pth`     |
| Deps            | PyTorch, torch2trt (optional), ROS ws `control_msg` |
| Phase 3 topic   | `/yopo_net/best_traj_visual`                     |
| RViz config     | `yopo_full_inference.rviz` (Trajectory group + Drone marker) |
| Topics added    | `/yopo_net/best_traj_visual`, `*_trajs_visual`, `/setpoints_cmd` |
| Jetson tmux     | Delegated to `yopo_viz_full_bringup.sh --mode add-pane` |
| Wrapper script  | `run_yopo_full.sh` — patches `lidar_topic` and sources ROS ws |

**Topic remapping:** `test_yopo_ros.py` defaults to `/laserMapping/cloud_registered_body`;
`run_yopo_full.sh` patches it to `/cloud_registered_body` to match the current faster_lio output.

**Pre-flight check (full):**
```bash
ssh nv@192.168.55.1 "test -x /home/nv/YOPO-C5Pro-Lidar/YOPO/run_yopo_full.sh && echo YOPO_OK"
ssh nv@192.168.55.1 "test -f /home/nv/YOPO-C5Pro-Lidar/ros_ws/devel/setup.bash && echo WS_OK"
```

---

## Pre-flight checklist

Individual checks:

| Prerequisite                      | Check command                                                  |
| --------------------------------- | -------------------------------------------------------------- |
| Docker + compose                  | `docker --version && docker compose version`                   |
| NVIDIA driver + container-toolkit | `nvidia-smi && nvidia-container-toolkit --version`             |
| noetic-desktop-full image         | `docker images osrf/ros:noetic-desktop-full`                   |
| GPU docker works                  | `docker run --rm --gpus all osrf/ros:noetic-desktop-full nvidia-smi` |
| X11 display                       | `echo $DISPLAY` (should be `:0` or `:1`)                       |
| xhost root access                 | `xhost +SI:localuser:root`                                     |
| Jetson USB reachable              | `ping -c1 192.168.55.1`                                        |
| SSH to Jetson                     | `ssh nv@192.168.55.1 "echo OK"`                                |
| sshpass (optional)                | `which sshpass`                                                 |
| yopo_inference package            | `ls deploy-side/src/control/yopo_inference/scripts/`            |

## Phased bringup details

### Phase 1: LiDAR + faster-LIO SLAM

**What happens:**
- Script creates a new tmux session `ros1-yopo-yopo-viz-debug` on Jetson
- Pane 0 (`lidar_launch.sh`) starts `roscore` → `livox_ros_driver2` → `faster_lio`
- Host polls `/cloud_registered_body` for data (up to 30s)

**Expected output:**
```
[yopo-viz] Phase 1/4: LiDAR + SLAM
[yopo-viz]   Waiting for LiDAR+SLAM (/cloud_registered_body) ...
[yopo-viz]   ✓ LiDAR+SLAM — publishing at 10.0 Hz
```

**Failure diagnostics:**
```
  ✗ LiDAR+SLAM — no data after 30s
  Diagnose:
    ssh nv@192.168.55.1
    tmux attach -t ros1-yopo-yopo-viz-debug
    Check pane 0 (lidar_launch.sh) for roslaunch errors
    Verify MID360 power & Ethernet (see lidar-debug skill)
    Check faster_lio mid360.yaml on device
```

### Phase 2: EKF odometry

**What happens:**
- Script splits tmux horizontally for pane 1
- Pane 1 (`ekf_launch.sh`) starts `ekf_quat_pose`
- Host polls `/ekf/ekf_odom` for data (up to 20s)

**Expected output:**
```
[yopo-viz] Phase 2/4: EKF odometry
[yopo-viz]   Waiting for EKF (/ekf/ekf_odom) ...
[yopo-viz]   ✓ EKF — publishing at 200.0 Hz
```

**Failure diagnostics:**
```
  ✗ EKF — no data after 20s
  Diagnose:
    ssh nv@192.168.55.1
    tmux attach -t ros1-yopo-yopo-viz-debug
    Check pane 1 (ekf_launch.sh) for errors
    Verify IMU data: rostopic hz /livox/imu
```

### Phase 3: YOPO preprocessing

**What happens:**
- Script splits tmux vertically under pane 0 for pane 2
- Pane 2 (`yopo_debug_launch.sh`) starts `yopo_lidar_preproc_node.py`
- Host polls `/yopo_net/perspective_depth` for data (up to 25s)

**Expected output:**
```
[yopo-viz] Phase 3/4: YOPO preprocessing
[yopo-viz]   Waiting for YOPO depth (/yopo_net/perspective_depth) ...
[yopo-viz]   ✓ YOPO depth — publishing at 10.1 Hz
[yopo-viz]   ✓ YOPO pipeline: 10 topics detected
```

**Failure diagnostics:**
```
  ✗ YOPO depth — no data after 25s
  Diagnose:
    ssh nv@192.168.55.1
    tmux attach -t ros1-yopo-yopo-viz-debug
    Check pane 2 (yopo_debug_launch.sh) for errors
    Verify topic remap:
      docker exec ros1-yopo-ros1-runtime-rviz \
        bash -c 'source /opt/ros/noetic/setup.bash && \
                 rosparam get /yopo_lidar_preproc/lidar_topic'
      Should be: /cloud_registered_body
    If LiDAR+SLAM OK but YOPO empty, check ROS topic names match
    (see AGENTS.md §5.5 Known Topic Mapping Inconsistencies)
```

### Phase 4: Docker RViz

**What happens:**
- Script arranges tmux panes in tiled layout
- Launches RViz inside the already-running Docker container
- Container uses host networking, connects to Jetson ROS master
- GPU passthrough for 3D rendering, X11 forwarding for window display

**Expected output:**
```
[yopo-viz] Phase 4/4: Docker RViz
[yopo-viz]   Launching RViz (close window to stop).
```

**Failure diagnostics:**
```
  RViz not found → exec: "rviz": executable file not found in $PATH
    Fix: docker exec -it ros1-yopo-ros1-runtime-rviz \
      bash -c 'source /opt/ros/noetic/setup.bash && rviz'

  GL errors / black window → GPU passthrough issue
    docker exec ros1-yopo-ros1-runtime-rviz nvidia-smi
    docker exec ros1-yopo-ros1-runtime-rviz \
      bash -c 'glxinfo | grep "OpenGL renderer"'
    Should show "NVIDIA GeForce RTX 4070 Ti SUPER" or similar

  "cannot open display" → X11 not forwarded
    xhost +SI:localuser:root
    echo $DISPLAY (should match host)
```

## What you see in RViz

Config: `deploy-side/src/bringup/config/yopo_debug.rviz`

```
┌──────────────────────────┬──────────────────────────────┐
│ 3D View                  │ Image: /yopo_net/range_image_colormap       │
│  - /cloud_registered_body│ Image: /yopo_net/perspective_depth_colormap │
│  - /yopo_net/depth_cloud_world  │ Image: /yopo_net/depth_inpainted_colormap │
│  - /ekf/ekf_odom (path)  │ Image: /yopo_net/depth_ceiling_colormap    │
│  - Grid                  │ Image: /yopo_net/depth_network_input_cm    │
│                          │                              │
│ Fixed frame: world       │ Colormap: JET (blue=near)    │
└──────────────────────────┴──────────────────────────────┘
```

### Pipeline stages (5 stages → 10 topics)

| # | Stage              | Raw topic                          | Colormap topic                                      | Meaning                          |
| - | ------------------ | ---------------------------------- | --------------------------------------------------- | -------------------------------- |
| 1 | Range image        | `/yopo_net/range_image` (float32) | `/yopo_net/range_image_colormap` (bgr8)             | Spherical 96x360, full 360 FOV    |
| 2 | Perspective depth  | `/yopo_net/perspective_depth`     | `/yopo_net/perspective_depth_colormap`              | Pinhole 96x160, 90 HFOV, pitch 22.5° |
| 3 | Inpainted depth    | `/yopo_net/depth_inpainted`       | `/yopo_net/depth_inpainted_colormap`                | Morphological hole filling       |
| 4 | Virtual ceiling    | `/yopo_net/depth_ceiling`         | `/yopo_net/depth_ceiling_colormap`                  | Plane injection at ceiling_z     |
| 5 | Network input      | `/yopo_net/depth_network_input`   | `/yopo_net/depth_network_input_cm`                  | Normalized [0,1], fed to ONNX     |

**Colormap reading:** Blue = near (0m), cyan/green = mid, yellow/orange = far, red = 20m+ (empty). Black pixels in Stage 2 = LiDAR holes; compare with Stage 3 to see fill quality.

Detailed per-stage interpretation → `yopo-lidar-preproc` skill §3.

## Fallback entry points

When you cannot use the skill directory (e.g., the skill files haven't been
synced to the device), these invocations achieve the same effect:

```bash
# Python orchestrator (full automated, no per-phase output)
uv run viz yopo

# Bash orchestrator (same logic via existing infra scripts)
bash deploy-side/tmux_scripts/host_yopo_debug_bringup.sh

# Bag mode
uv run viz yopo --bag /path/to/your.bag
bash deploy-side/tmux_scripts/host_yopo_debug_bringup.sh --bag /path/to/your.bag
```

## Files involved

| File | Role |
|---|---|
| `.agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh` | Phased orchestrator (recommended entry) |
| `.agents/skills/yopo-viz-bringup/check_env.sh` | Pre-flight environment check |
| `c5pro/cli/viz.py` | Python orchestrator (fallback) |
| `docker/deploy.compose.rviz.yml` | Docker Compose for RViz container |
| `deploy-side/tmux_scripts/yopo_debug_bringup.sh` | Jetson tmux: preproc mode (writing-tmux compliant) |
| `deploy-side/tmux_scripts/yopo_viz_full_bringup.sh` | Jetson tmux: full mode (writing-tmux compliant) |
| `deploy-side/tmux_scripts/infra_scripts/lidar_launch.sh` | LiDAR + faster_lio launcher |
| `deploy-side/tmux_scripts/infra_scripts/ekf_launch.sh` | EKF launcher |
| `deploy-side/tmux_scripts/infra_scripts/yopo_debug_launch.sh` | YOPO preproc launcher |
| `deploy-side/src/bringup/config/yopo_debug.rviz` | RViz panel layout (preproc mode) |
| `deploy-side/src/bringup/config/yopo_full_inference.rviz` | RViz panel layout (full mode) |
| `deploy-side/src/control/yopo_inference/launch/yopo_preprocess_debug.launch` | ROS launch (preproc debug) |
| `deploy-side/src/control/yopo_inference/scripts/yopo_lidar_preproc_node.py` | Preprocessing node |
| `${OLD_REPO_PATH}/YOPO/test_yopo_ros.py` (Jetson) | Full inference node (C5-lidar-yopo) |
| `${OLD_REPO_PATH}/YOPO/run_yopo_full.sh` (Jetson) | Full inference wrapper (lidar_topic patch) |
| `${OLD_REPO_PATH}/ros_ws/` (Jetson) | Separate catkin workspace for full mode |

## Cleanup

| Component | How to stop |
|---|---|
| Docker container | **Auto:** close RViz window (script handles `compose down` via trap)<br>**Manual:** `docker compose -f docker/deploy.compose.rviz.yml down` |
| Jetson tmux session | `ssh nv@192.168.55.1 "bash /home/nv/ros1-yopo/deploy-side/tmux_scripts/kill.sh"` |
| All ROS on Jetson | `ssh nv@192.168.55.1 "tmux kill-server"` (nuclear) |

## Repository mapping

| Repo / directory                                    | Host           | Jetson         | Role                          |
| --------------------------------------------------- | -------------- | -------------- | ----------------------------- |
| `ros1-yopo/deploy-side/src/control/yopo_inference/`   | development    | runtime        | ROS preproc + inference       |
| `ros1-yopo/docker/deploy.compose.rviz.yml`           | launches here  | —              | RViz container                |
| `ros1-yopo/.agents/skills/yopo-viz-bringup/`         | launches here  | —              | Orchestration scripts         |
| `ros1-yopo/deploy-side/tmux_scripts/yopo_viz_full_bringup.sh` | development | runtime | Full-mode tmux session |
| `YOPO-C5Pro-Lidar/` (Jetson only)                    | —              | dev/train      | Full inference (test_yopo_ros, PyTorch model) |
| `YOPO-C5Pro-Lidar/ros_ws/` (Jetson only)             | —              | runtime        | ROS packages for full mode |

## Related skills

| Skill | Relation |
|---|---|
| `yopo-lidar-preproc` | Pipeline interpretation, colormap reading guide |
| `docker-rviz-debug` | 6 Docker RViz failure modes with diagnosis steps |
| `ros-debug-bringup` | ROS launch XML pitfalls, Python lazy import for debug mode |
| `writing-tmux` | tmux session lifecycle, kill.sh conventions |
| `yopo-vc-sync` | Sync YOPO workspace to Jetson for modification/deploy |
| `lidar-debug` | LiDAR bringup failures, mid360 JSON config |

## Exit codes

| Code | Meaning | Implication |
|---|---|---|
| 0 | Success | RViz closed normally, all phases passed |
| 1 | Pre-flight failed | Fix environment issue and retry |
| 2 | Phase 1 (LiDAR+SLAM) failed | Hardware or driver issue |
| 3 | Phase 2 (EKF) failed | State estimation problem |
| 4 | Phase 3 (YOPO) failed | Topic remap or node crash |
| 5 | Phase 4 (Docker/RViz) failed | GPU/X11/Docker configuration issue |
| 6 | Interrupt/unexpected | See stderr for details |

---

## Lessons learned (development pitfalls)

Three bugs encountered during development, with root causes and fixes.

### 1. `pipefail` + `head | grep` pipeline kills health checks

**Symptom:** Phase always times out, but manual `docker exec ... rostopic echo -n 1` returns data immediately.

**Root cause:**
```
set -o pipefail
if docker exec ... | head -c 10 | grep -q .; then ...
```
`head -c 10` reads 10 bytes then closes pipe → `docker exec` receives SIGPIPE → exit 141.
`pipefail` reports exit 141 as the pipeline exit code → `if` treats it as FALSE.

**Fix:** Capture output via `$()` instead of piping, then test string length:
```bash
# WRONG — pipefail + SIGPIPE causes silent failure
fct_docker_exec "..." | head -c 10 | grep -q . && echo OK

# CORRECT — capture avoids pipe
output=$(fct_docker_exec "..." 2>/dev/null) || true
[ -n "$output" ] && echo OK
```

**Applicability:** Any bash script with `set -o pipefail` that uses `| head | grep`
in an `if` condition — the pipe writer receives SIGPIPE when the reader closes
early, and `pipefail` turns that into a non-zero exit.

---

### 2. `ssh -f` + base64 pipe loses tmux commands

**Symptom:** `tmux split-window` or `send-keys ... C-m` sent via `fct_ssh_bg`
(base64 + `ssh -f`) silently fail. Pane not created, or command text appears
in pane but not executed.

**Root cause:** The pipeline `echo <base64> | base64 -d | bash` processes
tmux commands through a non-interactive bash reading from stdin. In this mode:
- `select-pane` + `split-window` combinations sometimes produce no effect
- `send-keys ... C-m` (Enter character) is not reliably transmitted
- The `\` line continuation character is consumed during string construction

**Fix: Delegate all tmux pane orchestration to Jetons-side scripts.** Host-side
`yopo_viz_bringup.sh` should not create or manipulate tmux panes directly.
Instead, SSH-invoke a script on the Jetson that handles tmux locally:

```bash
# WRONG — host-side pane management through base64 pipe
fct_ssh_bg "tmux select-pane ... && tmux split-window ... && tmux send-keys ... C-m"

# CORRECT — delegate to a Jetson-side script
fct_ssh_bg "bash deploy-side/tmux_scripts/yopo_viz_full_bringup.sh --mode add-pane"
```

The Jetson-side script uses `writing-tmux` conventions (see skill) and runs
`tmux` commands directly in a local bash shell, avoiding base64 pipe issues.

**Exception:** `tmux new-session` / `split-window` with a **shell-command
argument** (not `send-keys`) works through base64:
```bash
# This works — shell-command in split-window argument
tmux split-window -h -t session:window 'bash script.sh'

# This may fail — send-keys through base64 pipe
tmux send-keys -t session:window 'command' C-m
```

---

### 3. writing-tmux compliance: pane indices, relative nav, staggered start

**Symptom:** Tmux pane layout unpredictable across runs, send-keys targets
wrong pane, or pane indices change after splits.

**Rule:** The project's `writing-tmux` skill mandates:

- **No explicit pane indices** (`session:window.pane-index`) in `send-keys`
  or `split-window -t` targets. Pane index values (`pane-base-index`) vary
  across tmux configurations.
- **All `send-keys` use `-t session:window`** (window-level). After
  `split-window`, the new pane is automatically focused, so window-level
  target sends to the correct pane.
- **Relative navigation** for cross-pane targeting via `select-pane -L/-R/-U/-D`.
- **Staggered startup.** Create all panes upfront, send commands with
  `sleep N && command`. Critical for ROS: multiple simultaneous `roslaunch`
  calls race to start `roscore`, causing `rosout` restart loops.

**2x2 layout template (writing-tmux compliant):**
```bash
# new pane is auto-focused after each split-window
tmux new-session ...                                     # pane 0 created
tmux send-keys -t session:window 'command-0' C-m          # pane 0

tmux split-window -h ...                                  # pane 1 auto-focused
tmux send-keys -t session:window 'sleep 6 && command-1'   # pane 1

tmux select-pane -L ...                                    # back to pane 0 (left)
tmux split-window -v ...                                   # pane 2 below pane 0
tmux send-keys -t session:window 'sleep 6 && command-2'   # pane 2

tmux select-pane -R ...                                    # to pane 1 (right)
tmux split-window -v ...                                   # pane 3 below pane 1
tmux send-keys -t session:window 'sleep 10 && command-3'  # pane 3

tmux select-layout tiled                                   # 2x2 grid
```

**See:** `writing-tmux` skill for full conventions and the 2x2 layout template.

---

### 4. LiDAR config: Mid360 vs Mid360s JSON + message type alignment

See `lidar-debug` skill for the complete diagnostic flow. Key invariants:

| Config file           | MID360 (`mid360.json`)     | Mid360s (`mid360s.json`)    |
|-----------------------|----------------------------|-----------------------------|
| SDK key               | `"MID360"` (uppercase)     | `"Mid360s"` (mixed case)    |
| `host_net_info`       | Object (per-port IP fields)| Array (single `host_ip`)    |
| `lidar_type` (YAML)   | 6 for PointCloud2          | 6 for PointCloud2           |
| `xfer_format` (launch)| 0 for PointCloud2          | 0 for PointCloud2           |

Mismatch between `lidar_type` (faster_lio YAML) and `xfer_format` (driver launch)
causes faster_lio to receive zero points (message type mismatch). Fix both to
`6` / `0` respectively. See `lidar-debug` §3.3.

This was the first failure encountered: `lidar_type: 1` (CustomMsg) with
`xfer_format: 1` (CustomMsg) — both "1" but incompatible across driver
generations (`livox_ros_driver` vs `livox_ros_driver2`).
