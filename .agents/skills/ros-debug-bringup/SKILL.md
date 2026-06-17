---
name: ros-debug-bringup
description: ROS bringup debugging patterns — roslaunch XML pitfalls, Python lazy imports for debug mode, independent node verification workflow. Use when debugging a ROS bringup session, writing a debug-only node mode, or troubleshooting launch file/import errors on remote targets.
---

# ros-debug-bringup

## Purpose

Common pitfalls when writing ROS bringup debug scripts and how to verify them independently. Covers patterns found in multiple ROS projects (launch file syntax, Python import design, node health checks).

Related skills:
- `writing-tmux` — rosout conflict prevention (roscore race in multi-pane tmux)
- `yopo-lidar-preproc` — concrete example: YOPO LiDAR preprocessing visualization

---

## 1. Roslaunch XML Syntax Pitfalls

### Comments must not contain `--`

The XML comment token is `<!--` ... `-->`. The character sequence `--` is **forbidden anywhere inside a comment** (it conflicts with the closing `-->` detection).

```xml
<!-- OK -->
<!-- Invalid -- because of double dash -->
```

Fix: replace `--` with a single `-` or rephrase:

```xml
<!-- Use single dash between clauses - like this -->
<!-- rosbag play --clock (NOK - double dash) -->
<!-- rosbag play with clock (OK - rephrased) -->
```

The `--` can hide inside option flags like `--clock`, `--loop`, `--bag`, or in prose like `-- this is an aside --`.

**Verification**:

```bash
python3 -c "
import xml.etree.ElementTree as ET
try:
    ET.parse('path/to/file.launch')
    print('XML well-formed')
except ET.ParseError as e:
    print(f'XML ERROR: {e}')
"
```

### Angle brackets in comments

While `>` and `<` are technically allowed inside XML comments, avoid them to prevent unpredictable behavior with some XML tools:

```xml
<!-- NOK: rosbag play <my.bag> has angle brackets -->
<!-- OK: rosbag play my.bag (angle brackets removed) -->
```

---

## 2. Python Lazy Import for Debug Mode

When a ROS node has a debug/preprocess_only mode that skips heavy dependencies (e.g. ONNX Runtime, PyTorch, TensorRT), those dependencies must not be imported at module level.

### Problem

```python
# yopo_net_lidar_node.py — module level
from yopo_net.policy_loader import PolicyLoader  # imports onnxruntime
# onnxruntime crashes on target if GLIBCXX version mismatch
# Crashes even if preprocess_only=True skips usage
```

Module-level imports run when the script starts, before `__init__` can check any flag.

**Scope**: This is a small-scope quick fix for debug-only nodes that bypass heavy
dependencies not yet installed on the target. It is **not** a substitute for proper
architectural separation — if the preprocessing logic is a standalone concern
(e.g. LiDAR->depth conversion), extract it into its own node rather than
coupling it to the inference node behind a preprocess_only flag.

### Fix: Lazy import inside the guard

```python
# Module level — import only what is always needed
from yopo_net.lidar_processor import LidarProcessor

class YopoNode:
    def __init__(self):
        preprocess_only = rospy.get_param("~preprocess_only", False)
        if not preprocess_only:
            from yopo_net.policy_loader import PolicyLoader  # lazy
            policy_loader = PolicyLoader(policy_dir)
```

Same for any module that pulls in platform-native dependencies (CUDA, ONNX, TensorRT, etc.).

### Which imports to guard

| Dependency           | Symptom if missing    | Guard?                         |
| -------------------- | --------------------- | ------------------------------ |
| `onnxruntime`        | GLIBCXX / libcuda err | Yes — debug mode skips network |
| `torch`              | CUDA/cuDNN error      | Yes — debug mode skips network |
| `cv_bridge`          | Python import error   | Only if not used in debug mode |
| `numpy`              | Common, rarely broken | No — almost always needed      |

---

## 3. Independent Node Verification Workflow

Before plugging into the full tmux bringup, verify a node in isolation:

```bash
# 1. Start roscore
roscore &
sleep 2

# 2. Start the node (standalone, with debug mode params)
roslaunch my_package my_debug.launch

# 3. Check node is alive
rosnode list
# Expected: /my_debug_node

# 4. Check topics are registered
rostopic list
# Expected: /debug/topic_a  /debug/topic_b

# 5. Check topic has data
rostopic hz /debug/topic_a --window=3 -w 5
# Expected: non-zero rate

# 6. Check message structure
rostopic echo /debug/topic_a -n 1 | head
# Expected: valid content (not all zeros/empty)

# 7. Check no error in log
rosnode info /my_debug_node 2>&1 | grep -i error || echo "No errors"
```

### Headless tmux verification (without attach)

```bash
tmux new-session -d -s test-session -n test bash
tmux send-keys -t test-session:test 'roslaunch my_package my_debug.launch' C-m
sleep 5
output=$(tmux capture-pane -t test-session:test -p -S -20)
echo "$output" | grep -q 'RLException' && echo "FAIL" || echo "PASS"
tmux kill-session -t test-session
```

---

## 4. Remote ROS Visualization via Docker

### When to use

On a **devel machine**, `ssh -X` forwarding of OpenGL/OGRE applications (rviz, Gazebo) often fails with:

```
OGRE EXCEPTION(3:RenderingAPIException): Invalid parentWindowHandle
```

This is because `ssh -X` uses indirect GLX rendering, which OGRE 2.1+ does not
support. The fix is to run rviz in a **local** Docker container that renders
directly on the host GPU, while connecting to the **remote** ROS master.

### Architecture

```
Devel machine (local GPU render)
  ┌──────────────────────────────────────┐
  │ Docker: ros-runtime-rviz             │
  │   X11/Wayland socket mount           │
  │   ROS_MASTER_URI=http://nv-V25.local:11311 │
  │   rviz -d /rviz_configs/debug.rviz   │
  └──────────┬───────────────────────────┘
             │ LAN / mDNS
             ▼
Device machine (Jetson)
  ┌──────────────────────────────────────┐
  │ roscore + lidar + ekf + debug node   │
  └──────────────────────────────────────┘
```

### Setup (devel machine)

1. Pull official ROS Noetic image (one-time):
   ```bash
   docker pull osrf/ros:noetic-desktop-full
   ```

2. **Recommended** — one command orchestrates device machine + local docker:
   ```bash
   uv run viz yopo
   uv run viz yopo --bag /path/to/bag.bag
   ```

3. **Manual** — step by step:

   Use `deploy.compose.rviz.yml` (in `docker/`). Key points:
   - Uses `osrf/ros:noetic-desktop-full` — official image with rviz + GUI libs, no custom build needed
   - `network_mode: host` — the container uses the host's network stack, so mDNS
     resolves `nv-V25.local`
   - `ROS_MASTER_URI=http://nv-V25.local:11311` — connects to Jetson's roscore
   - rviz config mounted read-only from `deploy-side/src/bringup/config/`

   ```bash
   # Start the container (devel machine)
   docker compose -f docker/deploy.compose.rviz.yml up -d

   # On device machine, start ROS stack without rviz:
   bash deploy-side/tmux_scripts/yopo_debug_bringup.sh --no-rviz

   # Launch rviz from the container (devel machine):
   docker exec -it V25-V25-ros1-yopo-ros1-runtime-rviz \
     rviz -d /rviz_configs/yopo_debug.rviz
   ```

### Verification

```bash
# Check container is alive
docker ps | grep rviz-runtime

# Check ROS connectivity (inside container)
docker exec V25-V25-ros1-yopo-ros1-runtime-rviz \
  bash -c 'source /opt/ros/noetic/setup.bash && rosnode list'

# Expected: at least yopo_lidar_preproc (or your debug node)
```

### Limitations

- Requires the dev machine and Jetson on the same network (mDNS/LAN).
- Display mount (`/tmp/.X11-unix` + DISPLAY) needs the host desktop to be
  running a Wayland or X11 session.
- The debug image must exist locally (`c5pro/ros1/V25-V25-ros1-yopo-debug`).

---

## 5. Delivery Checklist

When delivering a ROS debug bringup script or node mode:

- [ ] Launch file XML validated (`python3 -c "import xml.etree.ElementTree; xml.etree.ElementTree.parse('file.launch')"`)
- [ ] No `--` inside XML comments
- [ ] Python node debug mode uses `rospy.get_param("~preprocess_only", False)`, not argparse
- [ ] Heavy imports (onnxruntime, torch, tensorrt) lazy-imported inside the debug guard
- [ ] Independent verification: node starts, topic registered, topic has data
- [ ] If multi-pane tmux: see `writing-tmux` skill for rosout race prevention
