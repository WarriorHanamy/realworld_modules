# Docker Image & Container Naming

All resource names derive from `{branch-norm}` — the branch name with `/`
replaced by `-`. For production: `{branch-norm}=realworld-modules`.

## Image Naming

Pattern: `vtol/{service}-{platform}:latest`

| Image | Platform | Service |
|-------|----------|---------|
| `vtol/l4t-ros2-base-jetson` | jetson (arm64) | Shared ROS2 base |
| `vtol/px4-connector-jetson` | jetson | PX4 uxrce_dds bridge |
| `vtol/lio-jetson` | jetson | FAST-LIO2 SLAM |
| `vtol/calib-lidar-imu-init-jetson` | jetson | LiDAR-IMU calibration |
| `vtol/bht-jetson` | jetson | Neural behavior |
| `vtol/plotjuggler-host` | host (amd64) | PlotJuggler viz |
| `vtol/fastlio-debug-host` | host (amd64) | RViz debug |

To build:

```bash
# On Jetson
docker build -t vtol/lio-jetson -f dockerfiles/lio.jetson.Dockerfile .

# On host
docker build -t vtol/fastlio-debug-host -f dockerfiles/fastlio-debug.host.Dockerfile .
```

## Container Naming

Pattern: `vtol-{service}-{stage}` or `{branch-norm}-{service}-{stage}`

| Example | Stage |
|---------|-------|
| `vtol-lio-prod` | production |
| `vtol-px4-connector-debug` | debug (manual test) |
| `vtol-plotjuggler-test` | CI / unit test |

## Tmux Session Naming

Pattern: `vtol-{purpose}`

| Session | Purpose |
|---------|---------|
| `vtol-bringup` | Full system bringup |
| `vtol-lio-debug` | FAST-LIO2 debug |
| `vtol-calib` | Calibration |

Cleanup:

```bash
tmux list-sessions -F '#{session_name}' | grep "^vtol-"
```

## SSH Host

Pattern: `nv@nv-{drone}.local` or `nv@192.168.55.1` (USB link).

## Workspace Path

Pattern: `/home/nv/{branch-norm}`

| Branch | Remote Path |
|--------|-------------|
| `realworld_modules` | `/home/nv/realworld_modules` |

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DOCKER_IMAGE` | `vtol/lio-jetson` | Override image tag |
| `DOCKER_CONTAINER` | `vtol-lio` | Override container base name |
| `ROS_DOMAIN_ID` | `30` | ROS2 domain isolation |
