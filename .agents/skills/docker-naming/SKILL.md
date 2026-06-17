---
name: docker-naming
description: Consistent naming conventions for Docker images, containers, tmux sessions, SSH hosts, and workspace paths across c5pro branches. Use when building images, naming containers, writing tmux scripts, or configuring deployment infrastructure.
---

# Docker Image & Container Naming

All resource names derive from `{branch-norm}` — the branch name with `/`
replaced by `-`. The device ID (`{drone}`) only appears in the mDNS hostname
(`nv-{drone}.local`); it is **not** a separate prefix in resource names.

| Variable        | Meaning                    | Example                              |
| --------------- | -------------------------- | ------------------------------------ |
| `{branch-norm}` | Branch name, `/` → `-`     | `ros1-yopo`, `chirp`, `{drone}-chirp`   |

## Image Naming

Pattern: `c5pro/ros1/{branch-norm}`

| Type   | Pattern                              | Example                       |
| ------ | ------------------------------------ | ----------------------------- |
| Base   | `c5pro/ros1/{branch-norm}`           | `c5pro/ros1/ros1-yopo`        |
| Base + | can have suffix `-debug`, `-jetson`  | `c5pro/ros1/ros1-yopo-jetson` |

To build:

```bash
docker build -t c5pro/ros1/ros1-yopo -f docker/deploy.Dockerfile .
```

## Container Naming

Pattern: `{branch-norm}-ros1-{purpose}-{stage}`

| Part        | Required? | Typical Values                  |
| ----------- | --------- | ------------------------------- |
| `{purpose}` | always    | `runtime`, `jetson`             |
| `{stage}`   | always    | `prod`, `test`, `debug`, `ephemeral` |

| Example                                      | Stage         |
| -------------------------------------------- | ------------- |
| `ros1-yopo-ros1-runtime-prod`                | production    |
| `ros1-yopo-ros1-runtime-test`                | CI / unit test |
| `ros1-yopo-ros1-runtime-debug`               | GUI / manual  |
| `ros1-yopo-ros1-jetson-test`                 | Jetson test   |

Declared via compose:

```yaml
container_name: ${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime}-test
```

## Tmux Session Naming

Pattern: `{branch-norm}-{name}`

| Name        | Example Session Name       |
| ----------- | -------------------------- |
| Bringup     | `ros1-yopo-bringup`        |
| YOPO debug  | `ros1-yopo-yopo-debug`     |
| Other tool  | `ros1-yopo-{tool-name}`    |

Session discovery for cleanup (`kill.sh`):

```bash
tmux list-sessions -F '#{session_name}' | grep "ros1-yopo-"
```

## SSH Host

Pattern: `nv@nv-{drone}.local`

| Drone | SSH Target          |
| ----- | ------------------- |
| `{drone}` | `nv@192.168.55.1`   |

## Workspace Path

Pattern: `/home/nv/{branch-norm}`

| Branch        | Remote Path                  |
| ------------- | ---------------------------- |
| ros1-yopo     | `/home/nv/ros1-yopo`         |

## Real Examples

| Branch        | Image                         | Container                                | Tmux Session           | SSH                 | Path                       |
| ------------- | ----------------------------- | ---------------------------------------- | ---------------------- | ------------------- | -------------------------- |
| `ros1-yopo`   | `c5pro/ros1/ros1-yopo`        | `ros1-yopo-ros1-runtime-test`            | `ros1-yopo-bringup`    | `nv@192.168.55.1` | `/home/nv/ros1-yopo`       |

## Environment Variables

| Variable         | Default                      | Purpose                                      |
| ---------------- | ---------------------------- | -------------------------------------------- |
| `DOCKER_IMAGE`     | `c5pro/ros1/ros1-yopo`        | Override image tag for local dev             |
| `DOCKER_CONTAINER` | `ros1-yopo-ros1-runtime`      | Override container base name (stage appended) |

## Cross-Reference

- `ci-cd` — container lifecycle (which stage runs what)
- `writing-tmux` — tmux session creation and cleanup scripts
