---
name: yopo-lidar-preproc
description: YOPO LiDAR-to-depth-image preprocessing pipeline visualization tooling — 5-stage pipeline interpretation, bringup commands, topic reference, RViz setup. Use when debugging the YOPO LiDAR preprocessing stage, verifying LiDAR->depth conversion quality, or tuning virtual ceiling parameters.
---

# yopo-lidar-preproc

## Purpose

Visualize and debug the YOPO LiDAR preprocessing pipeline that converts MID360 point clouds to 96x160 perspective depth images for the YOPO neural network. Provides 10 ROS Image topics (5 raw float32 + 5 JET colormap) for the 5-stage pipeline, plus trajectory and depth cloud visualizations.

Related skills:
- `ros-debug-bringup` — XML pitfalls, Python lazy import, verification workflow
- `writing-tmux` — rosout conflict prevention in multi-pane sessions

---

## Pipeline Overview

```
Raw LiDAR point cloud (/cloud_registered_body)
  │
  ├─ Stage 1: Spherical range image     (96x360, spherical projection)
  │   Topic: /yopo_net/range_image
  │
  ├─ Stage 2: Perspective depth         (96x160, pinhole, pitch-aligned)
  │   Topic: /yopo_net/perspective_depth
  │
  ├─ Stage 3: Hole filling (morphology) (96x160, erode-diffuse)
  │   Topic: /yopo_net/depth_inpainted
  │
  ├─ Stage 4: Virtual ceiling           (96x160, plane injection)
  │   Topic: /yopo_net/depth_ceiling
  │
  └─ Stage 5: Network input             (96x160, normalized [0,1])
      Topic: /yopo_net/depth_network_input
```

Each stage publishes **two** topics: raw float32 distance [m] and BGR8 JET colormap (`*_colormap` suffix). The colormap uses `cv2.COLORMAP_JET`: blue=near (0m), red=far (20m+).

Additional visualization topics:

| Topic                                | Type        | Content                       |
| ------------------------------------ | ----------- | ----------------------------- |
| `/yopo_net/depth_cloud_world`          | PointCloud2 | Backprojected depth in world  |
| `/yopo_net/lattice_trajs_visual`      | PointCloud2 | Lattice primitive trajectories |
| `/yopo_net/best_traj_visual`          | PointCloud2 | Selected optimal trajectory   |
| `/yopo_net/trajs_visual`              | PointCloud2 | All trajectories with scores  |

---

## Quick Start

### Live LiDAR mode (Jetson, MID360 connected)

```bash
# One-command bringup (on Jetson directly, rviz via SSH -X)
bash deploy-side/tmux_scripts/yopo_debug_bringup.sh
```

Needs `ssh -X` for rviz. If rviz crashes (OGRE indirect GLX), use host mode:

### Host mode (devel machine, rviz via Docker)

Orchestrates device-machine bringup + local Docker rviz:

```bash
# Prerequisites: docker pull osrf/ros:noetic-desktop-full  (one-time)

# Recommended (devel machine):
uv run viz yopo
uv run viz yopo --bag /path/to/bag.bag

# Fallback (direct bash):
bash deploy-side/tmux_scripts/host_yopo_debug_bringup.sh
bash deploy-side/tmux_scripts/host_yopo_debug_bringup.sh --bag /path/to/bag.bag
```

### Rosbag replay mode (on Jetson)

```bash
bash deploy-side/tmux_scripts/yopo_debug_bringup.sh --bag /path/to/your.bag
```

Requires bag with: `/cloud_registered_body` + `/ekf/ekf_odom`.

---

## Stage-by-Stage Reading Guide (Colormap Interpretation)

### Stage 1: Range Image (96x360)

Spherical projection: azimuth (0-360 deg) on X axis, elevation (-7 to 52 deg) on Y axis. Shows the full 360-degree LiDAR field of view in a single 2D image.

- Blue/cyan bands at bottom = ground returns near the drone
- Red/orange band near row 10 = sky/empty at max range
- Dark gaps = missing returns (objects too close, too reflective, or outside FOV)

### Stage 2: Perspective Depth (96x160)

Pinhole camera model pitched 22.5 deg upward. This is the actual network input format. Shows only the forward-facing 90 deg HFOV.

- Bright band at bottom center = ground directly below/forward
- Green/yellow = mid-range obstacles (5-15m)
- Red = far/empty (20m max)
- Black speckles = holes (no LiDAR return in that pixel)

### Stage 3: Inpainted Depth

Morphological erosion (5x5, 2 iterations) fills black holes by diffusing nearby valid depth values. Compare with Stage 2 to see which holes were filled.

- Previously black speckles should now show nearby colors
- Good indicator of LiDAR density vs. topology complexity

### Stage 4: Virtual Ceiling

A horizontal ceiling plane at `ceiling_z` (default 3.0m) is projected into far/empty pixels. This provides a spatial boundary constraint for the planner.

- Red regions from Stage 3 may now show green/blue if ceiling intersects that pixel
- The ceiling appears as a gradient: closer at the drone, farther at the horizon
- Effective when the drone flies under structures (trees, roof, bridge)

### Stage 5: Network Input (Normalized)

`depth / max_dist` clipped to [0,1]. Black = 0m (very close), white = 1.0 (20m+ or max range). This is the actual tensor fed into the YOPO ONNX model.

---

## RViz Config

File: `deploy-side/src/bringup/config/yopo_debug.rviz`

Layout:

```
┌───────────────────────────┬──────────────────────────────┐
│ 3D View                   │ Image: range_image_colormap  │
│  - Raw LiDAR cloud        │ Image: perspective_depth_cm  │
│  - Depth cloud world      │ Image: depth_inpainted_cm    │
│  - Lattice trajectories   │ Image: depth_ceiling_colormap│
│  - Best trajectory        │ Image: depth_network_input_cm│
│  - EKF odometry           │                              │
│  - Grid                   │                              │
│                           │                              │
│ Fixed frame: world        │ Colormap: JET                │
└───────────────────────────┴──────────────────────────────┘
```

Raw float32 images are also available (duplicate Image display, set topic to e.g. `/yopo_net/perspective_depth`) for precise distance reading via RViz cursor hover.

---

## Troubleshooting

### No topics appear in RViz

1. Check nodes are running: `rosnode list | grep yopo_net_lidar`
2. Check roscore is alive: `rosnode list 2>/dev/null`
3. Check LiDAR data is flowing: `rostopic hz /cloud_registered_body`
4. If no LiDAR: try `--bag` mode

### All depth images are solid red (20m)

LiDAR data is not being received by the yopo node:
- Check topic remap: `rosparam get /yopo_net_lidar/lidar_topic`
- Check point cloud frame: yopo node expects body-FLU; if the topic publishes in a different frame, the perspective projection will map points to wrong pixels

### Depth image has many black holes

Normal for LiDAR at distance. The inpainted version should reduce them. If holes persist after inpaint, increase LiDAR accumulation:
- In launch file: add `<param name="lidar_accum_frames" value="4" />`

### Virtual ceiling not visible

- Check param: `rosparam get /yopo_net_lidar/virtual_ceiling_enable`
- Check ceiling_z (default 3.0m). If drone is above 3m, ceiling is above the drone and won't intersect any camera rays.
- Ceiling is only visible when drone is below ceiling_z and looking upward.

### rosout restart loop

See `writing-tmux` skill: roscore race condition. Use the fix: explicit `roscore &` before any `roslaunch`.

### Node crashes: "onnxruntime import error"

Preprocess-only node should NOT need onnxruntime. Check module-level imports:
- See `ros-debug-bringup` skill — Python lazy import section
- Fix: move `from yopo_net.policy_loader import PolicyLoader` inside the `preprocess_only` guard in `__init__`

---

## Files Reference

| File                                                                           | Role                     |
| ------------------------------------------------------------------------------ | ------------------------ |
| `deploy-side/src/control/yopo_inference/launch/yopo_preprocess_debug.launch`     | ROS launch (debug mode)  |
| `deploy-side/src/control/yopo_inference/scripts/yopo_lidar_preproc_node.py`       | Standalone preproc node  |
| `deploy-side/src/control/yopo_inference/scripts/yopo_net_lidar_node.py`          | Full inference node      |
| `deploy-side/src/control/yopo_inference/src/yopo_net/lidar_processor.py`         | LiDAR->depth pipeline    |
| `deploy-side/src/bringup/config/yopo_debug.rviz`                                | RViz layout              |
| `deploy-side/tmux_scripts/yopo_debug_bringup.sh`                                | One-command bringup      |
| `deploy-side/tmux_scripts/infra_scripts/yopo_debug_launch.sh`                   | YOPO pane launcher       |
