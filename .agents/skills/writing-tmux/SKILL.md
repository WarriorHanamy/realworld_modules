# writing-tmux

## Session Naming Convention

| Scope | Pattern | Example |
|-------|---------|---------|
| Perpetual | `vtol-*` prefix | `vtol-bringup` |
| Ephemeral | `<name>-test` | `lio-calib-test` |
| Delivery | `<name>-prod` | `lio-prod` |

Session name is the first `readonly` variable at the top of every script.

## Quick Start

Minimal headless script:

```bash
#!/usr/bin/env bash
set -euo pipefail

SELF="vtol-bringup"
STAGE="${TMUX_STAGE:-test}"
readonly SESSION="${SELF}-${STAGE}"

trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT INT TERM ERR
tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

tmux new-session -d -s "$SESSION" -n main
tmux send-keys -t "$SESSION:main" 'echo hello' Enter
```

Run with `bash script.sh` or `TMUX_STAGE=prod bash script.sh`.

## Workflow

### Pre-flight

```bash
tmux kill-session -t "${SESSION}" 2>/dev/null || true
```

### Trap cleanup (headless only)

```bash
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT INT TERM ERR
```

### Send keys

```bash
tmux send-keys -t "${SESSION}:window" 'command' Enter
```

### Capture output

```bash
output=$(tmux capture-pane -t "${SESSION}:window" -p)
```

### Pane layout

| Panes | Layout | tmux command |
|-------|--------|--------------|
| 2 | 1x2 side-by-side | `split-window -h` |
| 4 | 2x2 tiled | `split-window -h` + `split-window -v` + `select-pane -L` + `split-window -v` |

**No explicit pane indices.** Use `send-keys -t session:window` and `select-pane -L/-R/-U/-D`.

### Container startup coordination

When multiple panes start Docker containers that depend on the same DDS
discovery:

```bash
tmux send-keys -t "${SESSION}:win" 'docker start vtol-lio' C-m
tmux send-keys -t "${SESSION}:win" 'sleep 6 && docker start vtol-px4-connector' C-m
tmux send-keys -t "${SESSION}:win" 'sleep 10 && docker exec -it vtol-lio rviz' C-m
```

## Verification Pattern

```bash
tmux new-session -d -s "$SESSION"
tmux send-keys -t "$SESSION" 'echo hello' Enter
sleep 0.3
output=$(tmux capture-pane -t "$SESSION" -p)
echo "$output" | grep -q hello && echo "PASS" || echo "FAIL"
```

## CI (headless)

1. Session name: `<name>-test` (derived from `SELF`)
2. `trap` covers EXIT INT TERM ERR
3. Pre-flight kill for idempotency
4. `new-session -d` headless
5. `send-keys` + `sleep 0.3–1.0` + `capture-pane` + `grep -q` assertion
6. No `attach` — trap cleans up on exit

### Template

```bash
#!/usr/bin/env bash
set -euo pipefail

SELF="vtol-bringup"
readonly SESSION="${SELF}-test"

trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT INT TERM ERR
tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

tmux new-session -d -s "$SESSION" -n main
tmux send-keys -t "$SESSION:main" 'uv run integration init' Enter
sleep 0.5

output=$(tmux capture-pane -t "$SESSION:main" -p)
echo "$output" | grep -q 'init' && echo "PASS" || echo "FAIL"

echo "ALL PASS"
```

## Delivery Checklist

### Interactive script

- [ ] `readonly SESSION` follows naming convention (`vtol-*` or `<name>-prod`)
- [ ] First action: `tmux kill-session -t "${SESSION}" 2>/dev/null || true`
- [ ] Ends with `tmux attach -t "${SESSION}"`
- [ ] `send-keys` uses single quotes for literals
- [ ] No pane index — only `select-pane -U/-D/-L/-R`
- [ ] Staggered container starts (6s delay) for DDS discovery
- [ ] Script is executable: `chmod +x`
- [ ] `run_scripts/tmux_utils.sh` sourced for lifecycle mgmt

### Headless/test script

- [ ] `trap` covers EXIT INT TERM ERR
- [ ] No `tmux attach`
- [ ] Assertion failures `exit 1`
- [ ] CI-pipeline compatible
