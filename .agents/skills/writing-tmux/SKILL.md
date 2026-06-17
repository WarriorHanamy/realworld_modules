---
name: writing-tmux
description: Covers tmux scripting patterns — session lifecycle, send-keys, capture-pane, trap cleanup, naming conventions. Use when writing tmux automation scripts, testing terminal workflows, or maintaining deploy-side/tmux_scripts/ in this repo.
---

# writing-tmux

## Session Naming Convention

This project recognizes two naming scopes:

| Scope       | Pattern                | Example                     |
|-------------|------------------------|-----------------------------|
| Perpetual   | `ros1-yopo-*` prefix          | `ros1-yopo-hover-debug`            |
| Ephemeral   | `<name>-test`          | `adjust-calib-test`         |
| Delivery    | `<name>-prod`          | `adjust-calib-prod`         |

Session names are defined as the **first** `readonly` variable at the top of every script. All create/list/kill calls reference only that variable — never a hardcoded string.

## Quick Start

Minimal headless script (self-cleaning):

```bash
#!/usr/bin/env bash
set -euo pipefail

SELF="adjust-calib"
STAGE="${TMUX_STAGE:-test}"
readonly SESSION="${SELF}-${STAGE}"

trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT INT TERM ERR

tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

tmux new-session -d -s "$SESSION" -n main
tmux send-keys -t "$SESSION:main" 'echo hello' Enter
```

Run with `bash script.sh` (test) or `TMUX_STAGE=prod bash script.sh` (prod).

## Interactive vs Headless

| Style         | Cleanup method                        | Typical use                     |
| ------------- | ------------------------------------- | ------------------------------- |
| Interactive   | Pre-flight kill only, ends with attach| `deploy-side/tmux_scripts/hover_debug.sh`   |
| Headless/test | `trap` + pre-flight kill, no attach   | CI, automated verification      |

## Workflow

### Pre-flight

Always kill any stale leftover before creating:

```bash
tmux kill-session -t "${SESSION}" 2>/dev/null || true
```

Existing scripts (hover_debug.sh, ee_calib.sh) follow this pattern.

### Trap cleanup (headless only)

```bash
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT INT TERM ERR
```

The variable reference must match the `readonly SESSION` exactly.

### Send keys

```bash
tmux send-keys -t "${SESSION}:window" 'command' Enter
```

Avoid quoting the command inside `send-keys` unless shell expansion is desired. Use single quotes for literal commands.

### Capture output

```bash
output=$(tmux capture-pane -t "${SESSION}:window" -p)
```

Pipe through `grep`, `sed`, or `cmp` for verification.

### Pane layout conventions

| Pane count | Layout | tmux command      | Visual        |
|------------|--------|-------------------|---------------|
| 2          | 1x2    | `split-window -h` | `[A | B]`     |
| 4          | 2x2    | tiled             | `[A | B]`<br>`[C | D]` |

Two-pane windows **always** use 1x2 (side-by-side, `split-window -h`). Never 2x1 (top-bottom).

### Pane navigation

**禁止使用显式 pane 索引（`window.pane-index`）创建或发送命令。** pane 索引值在不同 tmux 配置（`pane-base-index`）下会变化，导致脚本不可移植。

正确做法：始终用 `send-keys -t session:window` 模式，配合 `split-window`（新 pane 自动 focus）和 `select-pane` 相对导航。

2x2 布局模板（来自 `ee_calib.sh` arm window）：

```bash
# top-left      send after new-session
# top-right     split-window -h + send
# bottom-right  split-window -v + send
# bottom-left   select-pane -L + split-window -v + send
tmux new-window -c "${DIR}" -t "${SESSION}" -n "arm"
tmux send-keys -t "${SESSION}:arm" 'command-1'          # top-left

tmux split-window -h -c "${DIR}" -t "${SESSION}:arm"
tmux send-keys -t "${SESSION}:arm" 'command-2'          # top-right

tmux split-window -v -c "${DIR}" -t "${SESSION}:arm"
tmux send-keys -t "${SESSION}:arm" 'command-3'          # bottom-right

tmux select-pane -L -t "${SESSION}:arm"
tmux split-window -v -c "${DIR}" -t "${SESSION}:arm"
tmux send-keys -t "${SESSION}:arm" 'command-4'          # bottom-left
```

`select-pane` 方向参数：

| Flag   | 含义     |
|--------|----------|
| `-U`   | 上       |
| `-D`   | 下       |
| `-L`   | 左       |
| `-R`   | 右       |

### rosout 冲突预防（ROS 多 pane 启动关键）

当 tmux 中多个 pane 同时执行 `roslaunch`（无已有 roscore 时），每个 `roslaunch` 都会尝试启动 roscore，导致 rosout 无限重启循环：

```
[rosout-1] started with pid [10296]
[ WARN] Shutdown request received.
Reason: [[/rosout] Reason: new node registered with same name]
[rosout-1] restarting process  ← 无限循环
```

**根因**：多个 `roslaunch` 在 `sleep` 延迟前同时检查 roscore，均发现无 roscore → 各自启动自己的 roscore → rosout 冲突。

**修复**：显式先启 roscore + pane 启动时间错开。

```bash
# 1. 显式 roscore（单次）
roscore &
sleep 3

# 2. 后续所有 roslaunch 都会复用已存在的 roscore
roslaunch bringup msg_MID360s.launch &

# 3. 多 pane 启动错开时间（6s 间隔）
tmux send-keys -t "${SESSION}:win" 'bash pane0_launch.sh' C-m   # t=0
tmux send-keys -t "${SESSION}:win" 'sleep 6 && bash pane1.sh' C-m  # t=6
tmux send-keys -t "${SESSION}:win" 'sleep 6 && bash pane2.sh' C-m  # t=6
tmux send-keys -t "${SESSION}:win" 'sleep 10 && rviz' C-m          # t=10
```

## Verification Pattern

```bash
tmux new-session -d -s "$SESSION"
tmux send-keys -t "$SESSION" 'echo hello' Enter
sleep 0.3
output=$(tmux capture-pane -t "$SESSION" -p)
echo "$output" | grep -q hello && echo "PASS" || echo "FAIL"
# trap fires → session killed
```

## CI

tmux 脚本的自动化验证采用 headless 模式。CI agent 自主运行，全程无需人工交互。

### 流程

1. Session 命名使用 `<name>-test` 模式（由 `SELF` 变量推导）
2. `trap` 覆盖 EXIT INT TERM ERR，确保退出时销毁 session
3. `has-session` + `kill-session` 做预清理（幂等）
4. `new-session -d` 创建 headless session
5. `send-keys` 发送命令，`sleep 0.3–1.0` 等待输出就绪
6. `capture-pane -p` 抓取 pane 输出，`grep -q` 做断言匹配
7. 末尾 **不调用 attach**，自然结束后 trap 触发清理
8. 全部断言通过则 `exit 0`，否则 `exit 1`

### 模板

```bash
#!/usr/bin/env bash
set -euo pipefail

SELF="hover-debug"
readonly SESSION="${SELF}-test"

trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT INT TERM ERR
tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

tmux new-session -d -s "$SESSION" -n main
tmux send-keys -t "$SESSION:main" 'uv run integration init' Enter
sleep 0.5

output=$(tmux capture-pane -t "$SESSION:main" -p)
echo "$output" | grep -q 'init' && echo "PASS: init launched" || echo "FAIL: init not found"

echo "ALL PASS"
```

### 集成

CI pipeline 中执行 `bash deploy-side/tmux_scripts/test_*.sh`，期望全部返回 0。

## CD

coding agent 在交付 tmux 脚本前，必须逐项验证以下 checklist。这是为了方便用户操作，确保脚本可直接投入现场使用。

### 交互式脚本交付 checklist（如 hover_debug.sh、ee_calib.sh）

- [ ] 顶部 `readonly SESSION` 符合命名惯例（`ros1-yopo-*` 永久 session 或 `<name>-prod` 交付 session）
- [ ] `fct_setup_session` 第一行为 `tmux kill-session -t "${SESSION}" 2>/dev/null || true`
- [ ] 末尾有 `tmux attach -t "${SESSION}"` 使用户能直接进入 session
- [ ] 全部 `send-keys` 使用单引号括字面量命令
- [ ] **Pane 创建不依赖显式索引** — 每次 `split-window` 后立即 `send-keys` 到窗口名，跨 pane 用 `select-pane -U/-D/-L/-R` 导航，禁用 `window.pane-index` 写法
- [ ] 每个 window 有注释块标明 pane 布局
- [ ] header 注释中包含 `See: docs/<filename>.md` 引用文档
- [ ] 脚本文件有 execute 权限（`chmod +x`）
- [ ] 用户能**直观确认** pane 布局正确、各命令按预期启动
- [ ] `bash deploy-side/tmux_scripts/kill.sh` 能清理该 session
- [ ] 多 pane 启动时 **非 lidar pane 带 `sleep` 延迟**，避免 `roslaunch` 竞争 roscore
- [ ] `lidar_launch.sh` 或首个 pane 中 **显式 `roscore & sleep 3`** 后再启动 `roslaunch`

### Headless/test 脚本交付 checklist

- [ ] `trap` 覆盖 EXIT INT TERM ERR
- [ ] 无 `tmux attach` 调用
- [ ] 断言失败时 `exit 1`
- [ ] CI pipeline 可直接调用，无需交互

## Existing Scripts

```
deploy-side/tmux_scripts/
├── delta_debug.sh          # interactive session ros1-yopo-delta-debug
├── ee_calib.sh             # interactive session ros1-yopo-ee-calib (2×2 panes)
├── hover_debug.sh          # interactive session ros1-yopo-hover-debug (2×2 panes)
├── kill.sh                 # list + kill all ros1-yopo-* sessions
├── bringup.sh              # full bringup: lidar + ekf + mavros + px4ctrl
├── sim.sh                  # interactive session ros1-yopo-sim
├── yopo_debug_bringup.sh   # YOPO LiDAR preprocessing debug (2×2, staggered)
└── infra_scripts/
    ├── yopo_debug_launch.sh # roslaunch yopo_inference yopo_preprocess_debug.launch
    └── ...
```

Run `bash deploy-side/tmux_scripts/kill.sh` to clean up all `ros1-yopo-*` sessions.

## Resource

- `~/.config/tmux/tmux.conf` — prefix C-Space, vi copy mode, Alt+Arrow pane nav
- `deploy-side/tmux_scripts/kill.sh` — reference implementation for bulk kill
