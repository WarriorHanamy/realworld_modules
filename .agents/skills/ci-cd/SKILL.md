---
name: ci-cd
description: Defines CI/CD/debug runtime policies and mandatory C++ build certification. Use when discussing CI, CD, Docker stages, C++ edits, catkin builds, or container-based validation in this repo.
---

# CI/CD Runtime

## Image & Container Naming Convention

Environment variable `DOCKER_STAGE` determines the suffix; default is `prod`:

| Scope | Image Tag               | Container Name            | 用途                           |
| ----- | ----------------------- | ------------------------- | ------------------------------ |
| Prod  | `c5pro/ros1/ros1-yopo`        | `ros1-yopo-ros1-runtime-prod`     | 正式演示 / 长期运行 / 循环展示 |
| Test  | `c5pro/ros1/ros1-yopo`        | `ros1-yopo-ros1-runtime-test`     | CI / 单测 / 临时验证           |
| Debug | `c5pro/ros1/ros1-yopo-debug`  | `ros1-yopo-ros1-runtime-debug`    | GUI 调试 / 手动排查 / strace   |

Derivation:

```bash
STAGE="${DOCKER_STAGE:-prod}"
CONTAINER="${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}-${STAGE}"
```

---

## Stage Lifecycle

### CI (Certification / Test)

- Container: `ros1-yopo-ros1-runtime-test`
- Use: code certification, catkin build, single-test, temporary validation
- ROS C++ `.c/.cpp/.h/.hpp` changes MUST be certified in CI container
- C++ package build MUST carry `*_BUILD_TEST=ON` when feasible
- Build failure blocks completion
- Prohibited: using `ros1-yopo-ros1-runtime` (suffix-less) or `ros1-yopo-ros1-runtime-prod` for certification

```bash
DOCKER_CONTAINER=ros1-yopo-ros1-runtime-test docker compose -p c5pro-test -f docker/deploy.compose.yml -f docker/deploy.compose.test.yml up -d
docker exec -i ros1-yopo-ros1-runtime-test bash -lc \
  'source /opt/ros/noetic/setup.bash && cd /home/rec/c5pro/deploy-side && catkin build odom_converter --no-status --cmake-args -DODOM_CONVERTER_BUILD_TEST=ON'
```

### CD (Delivery / Prod)

- Container: `ros1-yopo-ros1-runtime-prod`
- Use: formal demo, long-running, cycle demo
- Only used after CI passes
- No `*_BUILD_TEST=ON` flags
- Not used to prove code correctness, only deployment/execution

```bash
DOCKER_CONTAINER=ros1-yopo-ros1-runtime-prod docker compose -p c5pro-prod -f docker/deploy.compose.yml -f docker/deploy.compose.prod.yml up -d
DOCKER_CONTAINER=ros1-yopo-ros1-runtime-prod bash docker/scripts/docker_build_workspace.sh
```

### Debug

- Container: `ros1-yopo-ros1-runtime-debug`
- Use: RViz, GUI, gdb, strace, manual troubleshooting
- Cannot serve as CI pass evidence
- Cannot replace prod demo environment

```bash
DOCKER_CONTAINER=ros1-yopo-ros1-runtime-debug docker compose -f docker/deploy.compose.yml -f docker/deploy.compose.debug.yml up -d
docker exec -it -e DISPLAY=$DISPLAY ros1-yopo-ros1-runtime-debug rviz
```

---

## Compose Profiles

### Baseline (`docker/deploy.compose.yml`)

```yaml
services:
  ros-runtime:
    build:
      context: .
      dockerfile: deploy.Dockerfile
    image: ${DOCKER_IMAGE:-c5pro/ros1/ros1-yopo}
    container_name: ${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}
    network_mode: host
    user: root
    volumes:
      - ${PWD}:${PWD}
      - /tmp/.X11-unix:/tmp/.X11-unix
      - ${XAUTHORITY:-${HOME}/.Xauthority}:/root/.Xauthority:ro
      - /dev:/dev
    environment:
      - DISPLAY=${DISPLAY:-}
      - QT_X11_NO_MITSHM=1
    entrypoint:
      - bash
      - -c
      - |
        source /opt/ros/noetic/setup.bash
        roscore &
        sleep 2
        echo "[${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}] roscore started."
        sleep infinity
volumes:
  uv-cache:
```

### Test (`docker/deploy.compose.test.yml` — CI/单测)

```yaml
services:
  ros-runtime:
    container_name: ${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}-test
    volumes:
      - /dev:/dev:ro
    entrypoint:
      - bash
      - -c
      - |
        set -e
        source /opt/ros/noetic/setup.bash
        roscore &
        sleep 3
        exec "$@"
```

### Prod (`docker/deploy.compose.prod.yml` — 正式演示)

```yaml
services:
  ros-runtime:
    container_name: ${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}-prod
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pgrep -x roscore || exit 1"]
      interval: 10s
      retries: 3
      start_period: 5s
```

### Debug (`docker/deploy.compose.debug.yml` — GUI 调试)

```yaml
services:
  ros-runtime:
    container_name: ${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}-debug
    image: ${DOCKER_IMAGE:-c5pro/ros1/ros1-yopo}-debug
    environment:
      - DISPLAY=${DISPLAY:-}
      - QT_X11_NO_MITSHM=1
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
      - QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
    volumes:
      - ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-0}:/tmp/wayland-0:ro
      - ${XDG_RUNTIME_DIR}:${XDG_RUNTIME_DIR}:ro
      - /tmp/.X11-unix:/tmp/.X11-unix
    entrypoint:
      - bash
      - -c
      - |
        source /opt/ros/noetic/setup.bash
        roscore &
        sleep 2
        echo "[debug] roscore started. Enter: docker exec -it ${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}-debug bash"
        sleep infinity
```

---

## ROS C++ CI Certification

This section is the mandatory CI protocol for any ROS C++ change.

### Trigger

Use for all ROS `.c/.cpp/.h/.hpp` changes, and also when changing:
- ROS topic names consumed by C++ nodes
- catkin package `CMakeLists.txt`
- launch parameters that affect C++ node runtime
- message/service dependencies used by C++ code

### Impact Mapping

Before editing, search for:
- the symbol/function/class being changed
- ROS topic names
- launch remaps
- YAML params
- CMake target names
- message/service types

Classify affected files as producer, consumer, launch/config, build system, or documentation.

### Pipeline

1. Map impact before editing.
2. Identify owning catkin workspace and package.
3. Modify the smallest correct set of files.
4. Add in-code documentation for non-obvious ROS topic, frame, unit, or parameter semantics.
5. Add `*_BUILD_TEST` compile definition in the package `CMakeLists.txt`:

   ```cmake
   option(ODOM_CONVERTER_BUILD_TEST "Enable odom converter build validation" OFF)
   if(ODOM_CONVERTER_BUILD_TEST)
     add_compile_definitions(ODOM_CONVERTER_BUILD_TEST)
   endif()
   ```

   Add a compile-time guard in the changed file:

   ```cpp
   #ifdef ODOM_CONVERTER_BUILD_TEST
   static_assert(true, "ODOM_CONVERTER_BUILD_TEST enabled");
   #endif
   ```

6. Build inside `ros1-yopo-ros1-runtime-test`:

   ```bash
   DOCKER_CONTAINER=ros1-yopo-ros1-runtime-test docker compose -p c5pro-test -f docker/deploy.compose.yml -f docker/deploy.compose.test.yml up -d
   docker exec -i ros1-yopo-ros1-runtime-test bash -lc \
     'source /opt/ros/noetic/setup.bash && cd /home/rec/c5pro/deploy-side && catkin build <pkg> --no-status --cmake-args -D<NAME>_BUILD_TEST=ON'
   ```

7. If affected across workspaces, build the main workspace first, then the delta arm workspace:

   ```bash
   docker exec -i ros1-yopo-ros1-runtime-test bash -lc \
      'source /opt/ros/noetic/setup.bash && cd /home/rec/c5pro/deploy-side/deps/delta_arm_driver && catkin_make --pkg <pkg> --cmake-args -D<NAME>_BUILD_TEST=ON'
   ```

8. Report build command, result, and remaining risks.

### Failure Handling

If build fails:
1. Capture the first relevant compile/link error.
2. Fix the root cause.
3. Rebuild in `ros1-yopo-ros1-runtime-test`.
4. Repeat until successful or blocked by missing external dependency.

### Final Report

Always report:
- changed C/C++ files
- affected ROS topics/params
- container build command
- build result
- any skipped broader build and why

---

## Known Risks

| 风险                       | 严重度 | 影响                                                         | 潜在修复方向                       |
| -------------------------- | ------ | ------------------------------------------------------------ | ---------------------------------- |
| 无 Wayland 透传            | 高     | Hyprland 下 rviz / GUI 工具完全不可用                        | Debug profile 加入 Wayland socket  |
| `/dev:/dev` 全设备挂载     | 中     | 容器可访问宿主机所有块设备，非舵机场景下不必要               | Test profile 移除 `/dev:/dev`      |
| `uv:latest` 浮动 tag       | 中     | 构建不可复现；上游 uv 破坏性更新会导致 CI 失效               | 固定到 `uv:0.5.x` 具体版本         |
| 单容器不区分 stage         | 中     | 当前 `schema.py` 只有一个 `DOCKER_CONTAINER`，suffix 不兼容   | schema.py 可通过 `DOCKER_STAGE` 环境变量动态生成 container name |
| 无 GPU passthrough         | 中     | `marsim_render` OpenGL 渲染在容器内不可用                     | 增加 `--gpus all` + `runtime: nvidia` (仅在带 GPU 的 host) |

---

## Resources

| 文件                                             | 作用                                                                 |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| `docker/deploy.Dockerfile`                             | 基础镜像: `osrf/ros:noetic-desktop-full` + 编译依赖                 |
| `docker/deploy.compose.yml`                             | 单服务 `ros-runtime`（docker/ 下集中管理）                          |
| `docker/scripts/docker_build_image.sh`                 | BuildKit 构建脚本: `DOCKER_BUILDKIT=1 docker build`                  |
| `docker/scripts/docker_build_workspace.sh`             | uv sync + catkin build + delta arm catkin_make                       |
| `c5pro/schema.py`                          | `DOCKER_IMAGE = "c5pro/ros1/ros1-yopo"` / `DOCKER_CONTAINER = "ros1-yopo-ros1-runtime"` |
| `c5pro/core/ros_shell.py`                   | 自动检测 host/docker 并路由 ROS 命令                                 |
| `c5pro/core/ros_env.py`                     | `ros_env_command()` — 用于 `docker exec` 内部的 env 拼装             |

### Related Skills

- `writing-tmux` — tmux session lifecycle for test/prod/demo scenarios
- `ssh-target-setup` — passwordless SSH for remote board debugging
- `mdns-host-discovery` — LAN hostname resolution when DNS is unavailable
