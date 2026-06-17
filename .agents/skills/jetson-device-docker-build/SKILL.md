# Jetson Device Docker Build

Native aarch64 Docker image builds on Jetson Orin NX for the VTOL stack.

## Image Specification

```
Image family:   vtol/{service}-jetson
Base:           dustynv/ros:humble-ros-base-l4t-r35.4.1
Build on:       Jetson Orin NX (aarch64)
L4T:            35.5.0 (JetPack 5.1.3)
ROS2:           Humble
```

**Constraint:** Must be built natively on Jetson. Cross-compilation of
TensorRT + CUDA + ROS2 is not supported.

## Dependency Version Matrix

| Component | Version | Source |
|-----------|---------|--------|
| ROS2 | Humble | base image |
| TensorRT | 8.5.2.2 | L4T apt (JetPack 5.1.3) |
| CUDA | 11.4 | L4T apt / base |
| cuDNN | 8.x | L4T apt |
| Python | 3.10 | Ubuntu 22.04 |
| FastDDS | Humble bundled | ROS2 Humble |

## Build Flow

```bash
# On Jetson (nv@192.168.55.1):
cd /home/nv/realworld_modules

# Build individual service images
docker build -t vtol/lio-jetson \
  -f linker/dockerfiles/lio.jetson.Dockerfile .

docker build -t vtol/px4-connector-jetson \
  -f linker/dockerfiles/px4_connector.jetson.Dockerfile .

docker build -t vtol/calib-lidar-imu-init-jetson \
  -f linker/dockerfiles/calib.jetson.Dockerfile .
```

## Smoke Test

After every build:

```bash
docker run --rm --runtime nvidia vtol/lio-jetson \
  bash -c '
    source /opt/ros/humble/setup.bash
    ros2 pkg list | grep -E "livox|fastlio"
    python3 -c "import numpy; print(\"numpy OK\")"
  '
```

## Maintenance

| Trigger | Action |
|---------|--------|
| JetPack upgrade | Update `FROM` tag → rebuild → re-smoke |
| New submodule version | `git submodule update --remote` → rebuild |
| L4T base image unavailable | Use closest earlier minor version (e.g. r35.4.1 for r35.5.0) |

### Image lifecycle

```bash
# List images
ssh nv@192.168.55.1 "docker images vtol/*-jetson"

# Remove old image
ssh nv@192.168.55.1 "docker rmi vtol/lio-jetson:<old-tag>"

# Tag with date
ssh nv@192.168.55.1 "docker tag vtol/lio-jetson vtol/lio-jetson:\$(date +%Y%m%d)"
```

Record IMAGE ID and build date in `STATUS.md` after each build.

## Known Risks

| Risk | Severity | Impact | Mitigation |
|------|----------|--------|------------|
| `dustynv/ros` tag missing | High | Build fails at FROM | Use closest minor version |
| `--runtime nvidia` required | Medium | Container crashes without GPU | Compose files enforce this |
| `--network host` required | Medium | Containers can't communicate without host network | All run scripts include this |
| `/etc/apt/sources.list.d/` conflicts | Low | apt update fails during build | Remove conflicting NVIDIA repo entries before build |

## Related skills

| Skill | Purpose |
|-------|---------|
| `nv-network-proxy` | Network proxy for Docker pull on Jetson |
| `ci-cd` | amd64 Docker CI conventions |
