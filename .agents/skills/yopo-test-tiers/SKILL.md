---
name: yopo-test-tiers
description: Four-tier test model for YOPO inference — module (Docker), pipeline (Docker), performance (Jetson), bringup (Jetson+FCU). Use when writing, running, or routing tests for the yopo_inference package.
---

# YOPO Test Tiers

## Hardware Reference

| Property       | Dev Machine (host)      | Jetson Orin NX (nv)        |
| -------------- | ----------------------- | -------------------------- |
| Architecture   | x86_64 (amd64)          | aarch64                    |
| OS             | Arch Linux              | Ubuntu 20.04.6 LTS         |
| ROS            | via Docker (`c5pro/ros1/ros1-yopo`) | Noetic, bare-metal         |
| CUDA           | host GPU (optional)     | 11.4 (JetPack 5.1.3)       |
| TensorRT       | —                       | 8.5.2.2                    |
| PyTorch        | —                       | 2.1.0 (nv23.6, aarch64)    |
| ONNX Runtime   | amd64 (Docker)          | not installed (need image) |
| Docker runtime | docker + compose        | 24.0.7 + nvidia-runtime    |
| Memory / Disk  | —                       | 7.3 GiB / 233G (131G free) |
| L4T / JetPack  | —                       | L4T 35.5.0 / JetPack 5.1.3 |
| SSH            | —                       | `nv@192.168.55.1`                |
| Workspace path | `$PWD`                    | `/home/nv/ros1-yopo`    |

**Key constraint**: TensorRT-accelerated inference only runs on Jetson. All tests that touch GPU, TensorRT, or real LiDAR hardware must target the device. Pure numpy/ONNX/geometric tests can run on the dev machine in Docker.

## Test Tier Model

| Tier | Label       | Pytest Marker | Runtime           | Requires                        | CI Gate |
| ---- | ----------- | ------------- | ----------------- | ------------------------------- | ------- |
| 0    | module      | (none)        | Docker amd64      | numpy, scipy, cv2               | PR      |
| 1    | pipeline    | (none)        | Docker amd64      | ONNX Runtime, PyTorch           | PR      |
| 2    | performance | `device_only`   | Docker aarch64    | TensorRT, CUDA, roscore, rosbag | release |
| 3    | bringup     | `device_only`   | Jetson bare-metal | FCU, LiDAR, MAVROS, px4ctrl     | manual  |

### Tier 0 — Module Correctness

Pure mathematical / geometric invariants. No inference, no ROS, no GPU.

**What to test**:
- `LidarProcessor` projection <-> backprojection roundtrip error < 0.05 m (KDTree)
- `inpaint` never overwrites valid pixels with larger distances
- Virtual ceiling geometry: ray-plane intersection matches analytic expectation
- `normalize_for_network` output range in [0, 1] and shape == (1, 1, H, W)

**Location**: `test/l0_module/`

### Tier 1 — Pipeline Integration

End-to-end correctness of the ONNX inference path with mock or offline data.

**What to test**:
- Full pipeline (mock depth + obs -> inference -> BatchedQuinticPolySolver -> PositionCommand)
- Ceiling injection interacts correctly with real obstacles (no obstacle masking)
- Model I/O shapes match spec (depth [1,1,96,160], obs [1,9,V,H])
- ONNX vs PyTorch numerical consistency on amd64 (CPU)

**Location**: `test/l1_pipeline/`

### Tier 2 — Device Performance & Precision

Requires the Jetson container (`c5pro/ros1/ros1-yopo-jetson`) with TensorRT, CUDA, roscore.

**What to test**:
- TensorRT engine vs ONNX output L2 error below threshold
- Per-stage latency: projection, inpaint, ceiling, network forward, postprocess (p50 / p99)
- Memory peak (CPU + GPU) during inference
- LiDAR rosbag replay -> perspective depth projection correctness (human via rviz, or automated with saved reference images)

**Environment check** (`conftest.py`):

```python
def pytest_runtest_setup(item):
    if "device_only" not in item.keywords:
        return
    if not socket.gethostname().lower().startswith("nv"):
        pytest.skip("requires Jetson device")
    try:
        import torch
        if not torch.cuda.is_available():
            pytest.skip("CUDA not visible")
    except ImportError:
        pytest.skip("torch not installed")
```

**Location**: `test/l2_performance/`

### Tier 3 — Bringup Smoke

Requires full hardware: FCU over USB-UART, LiDAR MID360, MAVROS, px4ctrl.

**What to test**:
- All bringup nodes launch without crash (tmux session health check)
- Topic liveliness: `/ekf/ekf_odom`, `/position_cmd`, `/mavros/setpoint_raw/attitude` published at expected rates
- Controller FSM transitions: MANUAL_CTRL -> AUTO_HOVER (safety prop off)

**Location**: `test/l3_bringup/`

## File Layout

```
deploy-side/src/control/yopo_inference/test/
+-- conftest.py                     # tier-agnostic fixtures (policy, lattice)
|                                   # + pytest_configure: registers markers
|                                   # + pytest_collection_modifyitems: auto-skip device tests on host
+-- test_sanity.py                  # existing 13 tests (tier 0+1, unchanged)
|
+-- l0_module/
|   +-- __init__.py
|   +-- test_lidar_processor.py
|
+-- l1_pipeline/
|   +-- __init__.py
|   +-- conftest.py                 # mock_data fixtures (test_data/ loader)
|   +-- test_inference_pipeline.py
|   +-- test_ceiling_injection.py
|
+-- l2_performance/
|   +-- __init__.py
|   +-- conftest.py                 # device + CUDA availability check
|   +-- test_trt_consistency.py
|   +-- test_latency.py
|   +-- test_replay_projection.py
|
+-- l3_bringup/
    +-- __init__.py
    +-- conftest.py                 # FCU/LiDAR/MAVROS availability check
    +-- test_bringup_smoke.py
```

## Pytest Markers & Auto-Routing

### Marker Registration (`conftest.py`)

```python
def pytest_configure(config):
    config.addinivalue_line("markers",
        "device_only: requires Jetson hardware (nv hostname + CUDA visible)")
```

### Auto-Skip on Host (`conftest.py`)

```python
import socket

def pytest_collection_modifyitems(config, items):
    is_device = socket.gethostname().lower().startswith("nv")
    skip_device = pytest.mark.skip(reason="requires Jetson device")
    for item in items:
        if "device_only" in item.keywords and not is_device:
            item.add_marker(skip_device)
```

### Usage

```bash
# Docker on dev machine -- auto-skips device tests
cd deploy-side && pytest src/control/yopo_inference/test/ -v

# Docker on dev machine -- explicit skip
pytest src/control/yopo_inference/test/ -m "not device_only" -v

# Jetson container -- runs everything that is available
docker exec -i ros1-yopo-ros1-jetson-test bash -lc \
  "cd /home/rec/c5pro/deploy-side && pytest src/control/yopo_inference/test/ -v"

# Jetson container -- tier 2+3 only
pytest src/control/yopo_inference/test/ -m "device_only" -v
```

## Test Data Convention

```
deploy-side/test_data/
+-- .gitkeep
+-- lidar_frames.npz              # ~5 frames MID360 body-frame pts (300KB, in git)
+-- sample_odom.jsonl             # matching odometry records (in git)
+-- *.bag                         # rosbag files (gitignored, managed via rsync)
```

- Small reference data (`lidar_frames.npz`, `sample_odom.jsonl`) committed -- used by tier 1 mock pipeline tests.
- Large rosbags excluded from git via `deploy-side/test_data/*.bag` in `.gitignore`.
- Rosbags recorded on Jetson with `rosbag record -O test_data/scene_001.bag /cloud_registered_body /ekf/ekf_odom`.
- rsync to dev machine with `C5PRO_RSYNC_EXTRAS="test_data/*.bag"`.

## Docker Environments

### amd64 CI Image (existing)

Used for tier 0+1 on the dev machine. Defined in `docker/deploy.Dockerfile`.

```bash
# CI entry (already exists)
bash docker/scripts/docker_ci_test.sh
```

After this skill is implemented, `docker_ci_test.sh` also runs pytest:

```bash
docker exec -i ros1-yopo-ros1-runtime-test bash -lc \
  "source devel/setup.bash && cd /home/rec/c5pro/deploy-side && \
   pytest src/control/yopo_inference/test/ -m 'not device_only' -v"
```

### Jetson aarch64 Test Image (new)

Defined in `docker/deploy.jetson.Dockerfile`. Based on L4T ROS image.

```bash
# Jetson-side entry (new)
bash docker/scripts/docker_jetson_test.sh [0+1|2|all]
```

**Image**: `c5pro/ros1/ros1-yopo-jetson`
**Container**: `ros1-yopo-ros1-jetson-test`
**Compose**: `docker/deploy.jetson.compose.yml`
**Key mounts**: `nvidia-container-runtime` for GPU, `/dev` for LiDAR

## CLI Invocation

| Command                                     | Where    | Tiers  |
| ------------------------------------------- | -------- | ------ |
| `uv run integration test`                   | dev host | 0 + 1  |
| `bash docker/scripts/docker_jetson_test.sh` | Jetson   | 0+1+2  |
| `bash docker/scripts/docker_jetson_test.sh 2` | Jetson   | 2 only |

Tier 3 (bringup) is invoked manually via `uv run prod bringup` -- not pytest-automated.

## CI Gate Policy

| Gate        | Required Pass  | Trigger              |
| ----------- | -------------- | -------------------- |
| PR          | Tier 0 + 1     | every commit         |
| Release tag | Tier 0 + 1 + 2 | before `v*` tag push |
| Pre-flight  | Tier 3         | every flight session |

**Failure handling**:
- Tier 0/1 failure -> block merge. Fix before any other work.
- Tier 2 failure -> block release. Investigate latency regression or TRT numerical drift.
- Tier 3 failure -> abort flight. Debug on ground before next attempt.

## Known Risks

| 风险                                 | 严重度 | 影响                                             | 缓解措施                                     |
| ------------------------------------ | ------ | ------------------------------------------------ | -------------------------------------------- |
| `onnxruntime-gpu` aarch64 wheel 不可用 | 高     | tier 2 TensorRT 推理延迟测试无法跑               | 降级：只用 ONNX CPU 延迟 + 裸机 PyTorch 对照 |
| L4T `dustynv/ros` r35.5.0 tag 不存在   | 中     | Dockerfile 的 FROM 行需调整                      | 用 r35.4.1，ABI 兼容 L4T 35.5.0              |
| Docker `--runtime nvidia` 冲突         | 中     | 裸机已有 Docker + ROS，容器 dev 设备映射可能冲突 | 用 compose `runtime: nvidia` + privileged      |
| rosbag 回放与实时推理时延差异        | 低     | tier 2 录制的 rosbag 回放比实时推理快            | 延迟测试分开做：回放测精度，实时测延迟       |
| test_data rosbag 大小                | 低     | .gitignore 排除，但 rsync 可能占带宽             | 只在 pre-release 时 rsync 完整 rosbag        |

## Resources

| 文件                                 | 作用                                     |
| ------------------------------------ | ---------------------------------------- |
| `.agents/skills/ci-cd/SKILL.md`        | Docker CI 容器规范、suffix 约定          |
| `.agents/skills/writing-tmux/SKILL.md` | tmux bringup 脚本规范、session 命名      |
| `docker/deploy.Dockerfile`             | amd64 CI/Prod 基础镜像                   |
| `docker/deploy.jetson.Dockerfile`      | aarch64 Jetson 测试镜像 (NEW)            |
| `docker/deploy.jetson.compose.yml`     | Jetson 容器编排 (NEW)                    |
| `docker/scripts/docker_ci_test.sh`     | amd64 CI 入口                            |
| `docker/scripts/docker_jetson_test.sh` | Jetson 测试入口 (NEW)                    |
| `deploy-side/test_data/`               | 测试数据目录 (partially new, gitignored) |
| `c5pro/shared.py`                      | `_is_local_target()` -- host vs device 检测 |
| `c5pro/core/ros_shell.py`              | `_detect_runtime()` -- host vs Docker 检测  |

### Related Skills

- `jetson-device-docker-build` -- Jetson Docker image native build + maintenance
- `ci-cd` -- Docker CI stage lifecycle, container naming conventions
- `writing-tmux` -- bringup session scripts for tier 3 smoke tests
- `ssh-target-setup` -- passwordless SSH for remote Jetson test execution
- `nv-network-proxy` -- network access for Jetson Docker image pull
