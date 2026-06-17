---
name: yopo-vc-sync
description: Sync YOPO-C5-feature-virtual-ceiling workspace to Jetson device via USB
             (192.168.55.1), catkin build, verify compilation.
---

# yopo-vc-sync

## Purpose

Sync `~/YOPO-C5-feature-virtual-ceiling/` from host to Jetson via USB RNDIS
(`192.168.55.1`), then `catkin build` the `ros_ws/` workspace and verify all
packages compile successfully. Use when modifying any C++/Python file in the
virtual-ceiling workspace and need to deploy & test on the drone.

**Always uses wired USB IP** (`192.168.55.1`) — no mDNS/WiFi dependency.

---

## Pre-flight (host-side check)

```bash
# 1. Confirm workspace exists on disk
test -d ~/YOPO-C5-feature-virtual-ceiling/ros_ws/src && \
  echo "=== workspace found ===" || \
  echo "[FAIL] ~/YOPO-C5-feature-virtual-ceiling/ros_ws/src/ not found"

# 2. Confirm USB link to device is up
ping -c1 -W1 192.168.55.1 && echo "=== USB OK ===" || echo "[FAIL] 192.168.55.1 unreachable"

# 3. Count ros packages (should be 10 catkin packages)
ls -d ~/YOPO-C5-feature-virtual-ceiling/ros_ws/src/*/package.xml | wc -l
```

---

## Sync (host)

```bash
rsync -avz --delete \
  --exclude build/ \
  --exclude devel/ \
  --exclude .catkin_tools/ \
  --exclude Livox-SDK2/ \
  --exclude '*.pyc' \
  --exclude '__pycache__/' \
  --exclude '*.o' \
  --exclude '*.so' \
  --exclude '.git/' \
  --exclude '.vscode/' \
  --exclude '.DS_Store' \
  --rsh='ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10' \
  ~/YOPO-C5-feature-virtual-ceiling/ \
  nv@192.168.55.1:/home/nv/YOPO-C5-feature-virtual-ceiling/
```

**Notes:**
- `Livox-SDK2/` is excluded — the static library (`liblivox_lidar_sdk_static.a`)
  is pre-installed on the device at `/usr/local/lib/`. Including it under
  `ros_ws/src/` would cause `catkin build` to fail (not a catkin package).
- `build/`, `devel/`, `.catkin_tools/` are excluded to avoid pushing stale
  build artifacts that may be from a different architecture (x86_64 vs aarch64).

---

## Build (on device)

```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 nv@192.168.55.1 "bash -c '
  set -e
  source /opt/ros/noetic/setup.bash
  cd /home/nv/YOPO-C5-feature-virtual-ceiling/ros_ws
  catkin config --init
  rm -rf build devel
  catkin build --no-status
'"
```

The `--no-status` flag reduces output noise; remove it if you need to see
per-package progress lines.

---

## Verify

### Check all packages produced binaries

```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 nv@192.168.55.1 "bash -c '
  ls /home/nv/YOPO-C5-feature-virtual-ceiling/ros_ws/devel/lib/
'"
```

### Check key executables

```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 nv@192.168.55.1 "bash -c '
  set -e
  DEVEL=/home/nv/YOPO-C5-feature-virtual-ceiling/ros_ws/devel
  test -f \$DEVEL/lib/px4ctrl/px4ctrl_node            && echo \"OK: px4ctrl_node\"
  test -f \$DEVEL/lib/ekf_quat/ekf_quat                && echo \"OK: ekf_quat\"
  test -f \$DEVEL/lib/livox_ros_driver2/livox_ros_driver2_node && echo \"OK: livox_ros_driver2_node\"
  test -f \$DEVEL/lib/fast_lio/laserMapping           && echo \"OK: fast_lio laserMapping\"
  test -f \$DEVEL/lib/fast_lio/preprocess             && echo \"OK: fast_lio preprocess\"
  echo \"=== all key executables present ===\"
'"
```

### Quick sanity: run a no-op ros command in the workspace

```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 nv@192.168.55.1 "bash -c '
  source /home/nv/YOPO-C5-feature-virtual-ceiling/ros_ws/devel/setup.bash
  rospack list 2>/dev/null | grep -E \"(px4ctrl|ekf_quat|fast_lio)\"
'"
```

---

## Package Build Order (auto-resolved by catkin)

```
cmake_utils (build helper, no deps)
  └→ quadrotor_msgs (messages, no catkin deps)
      └→ uav_utils     (depends: quadrotor_msgs)
          └→ px4ctrl    (depends: quadrotor_msgs, uav_utils, mavros_msgs)
mavros_msgs              (messages, system dep: mavros)
livox_ros_driver2        (depends: system liblivox_lidar_sdk_static.a)
  └→ FAST_LIO            (depends: livox_ros_driver2)
incremental_map_publisher (standalone)
ekf_quat_pose            (standalone, PKG name: ekf_quat)
```

No manual ordering needed — `catkin build` topologically sorts by dependency.

---

## Troubleshooting

### Livox SDK static library not found

If `catkin build` fails with `find_library(LIVOX_LIDAR_SDK_LIBRARY)` error:

```bash
ssh nv@192.168.55.1 "ls -la /usr/local/lib/liblivox_lidar_sdk_static.a"
# Missing? Reinstall Livox SDK2 on device.
```

### USB link down

```bash
# On host: check USB network interface
ip a show usb0 2>/dev/null || ip a show enp0s20f0u1 2>/dev/null

# On device (if accessible): check IP
ssh nv@192.168.55.1 "ip a show usb0 | grep 192.168.55"
```

### Catkin build fails on a specific package

```bash
SH=/home/nv/YOPO-C5-feature-virtual-ceiling/ros_ws
ssh nv@192.168.55.1 "bash -c 'source /opt/ros/noetic/setup.bash && cd $SH && catkin build <pkg> --no-status'"
```

### Mixed C++ standard warnings

`FAST_LIO` uses C++17, other packages use C++11. These are benign because
catkin tools compile each package independently with its own flags.

---

## Related Skills

- `ci-cd` — Docker-based CI build pipeline, container naming conventions
- `ros-debug-bringup` — ROS launch debugging, XML pitfalls, lazy import patterns
- `setup-device` — Initial Jetson setup (Livox SDK2, ROS Noetic, catkin_tools)
- `yopo-lidar-preproc` — LiDAR preprocessing pipeline visualization, topic reference
