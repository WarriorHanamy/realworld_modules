---
name: jetson-device-docker-build
description: Jetson Orin NX Docker image build and maintenance for YOPO test infrastructure. Covers native aarch64 L4T image building, ONNX Runtime CPU-only strategy, TensorRT/PyTorch version alignment, and smoke testing. Use when building, rebuilding, or verifying the Jetson test container.
---

# Jetson Device Docker Build

## Image Specification

```
Image:      c5pro/ros1/ros1-yopo-jetson
Container:  ros1-yopo-ros1-jetson-test
Base:       dustynv/ros:noetic-ros-base-l4t-r35.4.1
Build on:   Jetson Orin NX (aarch64)
L4T:        35.5.0  (JetPack 5.1.3)
```

**Constraint**: THE IMAGE MUST BE BUILT NATIVELY ON THE JETSON. Cross-compilation (qemu amd64->aarch64) of TensorRT + ROS is not supported.

## Dependency Version Matrix

| Component    | Version           | Source                                |
| ------------ | ----------------- | ------------------------------------- |
| ROS          | noetic (Ubuntu 20) | base image                           |
| TensorRT     | 8.5.2.2           | L4T apt repo (JetPack 5.1.3)         |
| CUDA         | 11.4              | L4T apt repo / base image            |
| cuDNN        | 8.x               | L4T apt repo                         |
| ONNX Runtime | 1.18+ (CPU only)  | `pip3 install onnxruntime`           |
| PyTorch      | 2.1.0 (nv23.6)    | NVIDIA aarch64 wheel (`cu118` index) |
| OpenCV       | 4.x (headless)    | `pip3 install opencv-python-headless`  |
| Python       | 3.8               | Ubuntu 20.04                          |

## Dockerfile

Maintained at `docker/deploy.jetson.Dockerfile`. The `FROM` tag MUST match the device's L4T version and MUST be verified before build:

```bash
# Verify base image tag exists before building
docker pull dustynv/ros:noetic-ros-base-l4t-r35.4.1
```

If the exact L4T tag is unavailable, use the closest earlier minor version (e.g. r35.4.1 for r35.5.0). Do NOT use a different major version (e.g. r32.x).

## Build Flow

```bash
# On Jetson (nv@192.168.55.1):
cd /home/nv/ros1-yopo
docker build -t c5pro/ros1/ros1-yopo-jetson \
  -f docker/deploy.jetson.Dockerfile .
```

Or use the build script:

```bash
bash docker/scripts/docker_build_jetson_image.sh
```

## Smoke Test

After every build:

```bash
docker run --rm --runtime nvidia c5pro/ros1/ros1-yopo-jetson \
  bash -c '
    python3 -c "import tensorrt; print(\"TensorRT\", tensorrt.__version__)"
    python3 -c "import torch; print(\"CUDA\", torch.cuda.is_available())"
    python3 -c "import onnxruntime as ort; print(\"providers\", ort.get_available_providers())"
    python3 -c "import cv2; print(\"OpenCV\", cv2.__version__)"
  '
```

Expected output:
```
TensorRT 8.5.2.2
CUDA True
providers ['TensorrtExecutionProvider', 'CUDAExecutionProvider', 'CPUExecutionProvider']
OpenCV 4.x
```

## Maintenance

| Trigger                     | Action                                              |
| --------------------------- | --------------------------------------------------- |
| JetPack upgrade on device   | Update `FROM` tag → rebuild → re-smoke              |
| Policy export with new ONNX | Smoke-test inference → check model output unchanged |
| `onnxruntime-gpu` available | Update Dockerfile → rebuild → tier 2 re-benchmark    |

### Image Lifecycle

```bash
# List image
docker images c5pro/ros1/ros1-yopo-jetson

# Remove old image
docker rmi c5pro/ros1/ros1-yopo-jetson:<old-tag>

# Tag a new build
docker tag c5pro/ros1/ros1-yopo-jetson c5pro/ros1/ros1-yopo-jetson:$(date +%Y%m%d)
```

Record the IMAGE ID and build date in `deploy-side/STATUS.md` after each build.

## Known Risks

| Risk                              | Severity | Impact                               | Mitigation                              |
| --------------------------------- | -------- | ------------------------------------ | --------------------------------------- |
| `dustynv/ros` r35.5.0 tag missing | High     | Build fails at `FROM`                | Use r35.4.1 (ABI compatible)            |
| ONNX Runtime GPU wheel unavailable| Medium   | tier 2 can't measure TRT full latency| Defer; use CPU ONNX + PyTorch baseline  |
| `--runtime nvidia` required       | Medium   | Container crashes without GPU runtime| Compose file enforces this              |

## Resources

| File                                 | Role                           |
| ------------------------------------ | ------------------------------ |
| `docker/deploy.jetson.Dockerfile`      | Image definition               |
| `docker/deploy.jetson.compose.yml`     | Container orchestration        |
| `docker/scripts/docker_build_jetson_image.sh` | Build entry point  |
| `docker/scripts/docker_jetson_test.sh` | Test entry point               |
| `c5pro/shared.py`                      | SSH/rsync helpers              |
| `deploy-side/STATUS.md`               | Deployment log                 |

### Related Skills

- `yopo-test-tiers` — testing tiers that consume this image
- `ci-cd` — amd64 Docker CI conventions (suffix pattern, compose profiles)
- `nv-network-proxy` — network for Docker pull on Jetson
