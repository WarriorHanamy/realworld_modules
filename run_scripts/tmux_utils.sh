#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# tmux_utils.sh — tmux orchestration helpers for run_scripts/
#
# Convention:
#  - All run scripts SHOULD source this file and use these helpers for
#    session/window/pane lifecycle and command injection.
#  - Raw `tmux` commands are disallowed outside this file, except for
#    explicitly documented escape hatches.
#  - The primary addressing model is **named windows**, not base-index.
# =============================================================================

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

fn_tmux_win_idx() {
  tmux show-option -g base-index 2>/dev/null | awk '{print $NF}'
}

fn_tmux_pane_idx() {
  tmux show-option -g pane-base-index 2>/dev/null | awk '{print $NF}'
}

fn_tmux__target_for_window() {
  # Resolve a window target string for tmux commands.
  # $1 = session, $2 = window name or index
  local session="${1:?session required}"
  local win="${2:?window required}"
  echo "${session}:${win}"
}

# -----------------------------------------------------------------------------
# Session lifecycle
# -----------------------------------------------------------------------------

fn_tmux_session_start() {
  # Start a new detached tmux session with a default window named 'main'.
  # Kills any existing session with the same name.
  #
  # Usage: fn_tmux_session_start <session_name>
  local session="${1:?session required}"
  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" -x 200 -y 50 -n main
}

fn_tmux_session_kill() {
  # Kill a tmux session if it exists.
  #
  # Usage: fn_tmux_session_kill <session_name>
  local session="${1:?session required}"
  tmux kill-session -t "$session" 2>/dev/null || true
}

fn_tmux_session_safe_start() {
  # Kill an existing session and wait until it is fully gone, then create
  # a fresh one.  This prevents "index N in use" errors caused by a
  # partially-destroyed old session lingering during the re-create window.
  #
  # Usage: fn_tmux_session_safe_start <session_name>
  local session="${1:?session required}"
  tmux kill-session -t "$session" 2>/dev/null || true
  local i=0
  while tmux has-session -t "$session" 2>/dev/null; do
    sleep 0.1
    ((i++))
    if (( i > 50 )); then          # 5 s safety timeout
      echo "WARNING: session '$session' did not die, force killing"
      tmux kill-server 2>/dev/null || true
      break
    fi
  done
  tmux new-session -d -s "$session" -x 200 -y 50 -n main
}

# -----------------------------------------------------------------------------
# Window management (named windows)
# -----------------------------------------------------------------------------

fn_tmux_window_new() {
  # Create a new window in a session and optionally rename it.
  # If the window already exists, the command is a no-op.
  #
  # Usage: fn_tmux_window_new <session> <window_name>
  local session="${1:?session required}"
  local win="${2:?window required}"
  local target
  target=$(fn_tmux__target_for_window "$session" "$win")
  # Check existence by trying to list windows; if window exists, skip creation
  if ! tmux list-windows -t "$session" 2>/dev/null | grep -qE "(^|:)$win($|:)"; then
    tmux new-window -t "$session" -n "$win"
    # Small stabilisation delay (best-effort, not mandatory)
    sleep 0.05
  fi
}

fn_tmux_window_rename() {
  # Rename an existing window.
  #
  # Usage: fn_tmux_window_rename <session> <old_name> <new_name>
  local session="${1:?session required}"
  local old_name="${2:?old_name required}"
  local new_name="${3:?new_name required}"
  tmux rename-window -t "$session:$old_name" "$new_name"
}

fn_tmux_window_select() {
  # Select (switch to) a window in a session.
  #
  # Usage: fn_tmux_window_select <session> <window_name>
  local session="${1:?session required}"
  local win="${2:?window required}"
  tmux select-window -t "$session:$win"
}

fn_tmux_window_exists() {
  # Return 0 if the window exists in the session; 1 otherwise.
  #
  # Usage: fn_tmux_window_exists <session> <window_name>
  local session="${1:?session required}"
  local win="${2:?window required}"
  tmux list-windows -t "$session" 2>/dev/null | grep -qE "(^|:)$win($|:)"
}

# -----------------------------------------------------------------------------
# Pane management (splitting inside a specific window)
# -----------------------------------------------------------------------------

fn_tmux_pane_run() {
  # Send a command to a specific pane within a window.
  # Default pane follows tmux pane-base-index.
  #
  # Usage: fn_tmux_pane_run <session> <window> [pane=<base-index>] <command>
  local session="${1:?session required}"
  local win="${2:?window required}"
  local default_pane
  default_pane=$(fn_tmux_pane_idx)
  local pane="${3:-$default_pane}"
  shift 3 || true
  tmux send-keys -t "${session}:${win}.${pane}" "$*" Enter
}

fn_tmux_pane_run_bash() {
  # Send a bash script (single line) to a specific pane.
  # Internally uses `bash -lc` so the script runs inside a login shell.
  #
  # Usage: fn_tmux_pane_run_bash <session> <window> [pane=<base-index>] <script_string>
  local session="${1:?session required}"
  local win="${2:?window required}"
  local default_pane
  default_pane=$(fn_tmux_pane_idx)
  local pane="${3:-$default_pane}"
  local script="${4:?script required}"
  local command
  printf -v command 'bash -lc %q' "$script"
  tmux send-keys -t "${session}:${win}.${pane}" "$command" Enter
}

fn_tmux_pane_run_heredoc() {
  # Send a multi-line bash script to a pane using a heredoc-friendly approach.
  # The caller provides a bash script string that may contain newlines.
  #
  # Usage: fn_tmux_pane_run_heredoc <session> <window> [pane=<base-index>] <multiline_script>
  local session="${1:?session required}"
  local win="${2:?window required}"
  local default_pane
  default_pane=$(fn_tmux_pane_idx)
  local pane="${3:-$default_pane}"
  local script="${4:?script required}"
  # Use printf to safely quote the script as a single argument to `bash -lc`
  local command
  printf -v command 'bash -lc %q' "$script"
  tmux send-keys -t "${session}:${win}.${pane}" "$command" Enter
}

fn_tmux_split_h() {
  # Split a pane horizontally. Operates on the given window and pane.
  #
  # Usage: fn_tmux_split_h <session> <window> [pane=<base-index>]
  local session="${1:?session required}"
  local win="${2:?window required}"
  local default_pane
  default_pane=$(fn_tmux_pane_idx)
  local pane="${3:-$default_pane}"
  tmux split-window -h -t "${session}:${win}.${pane}"
}

fn_tmux_split_v() {
  # Split a pane vertically. Operates on the given window and pane.
  #
  # Usage: fn_tmux_split_v <session> <window> [pane=<base-index>]
  local session="${1:?session required}"
  local win="${2:?window required}"
  local default_pane
  default_pane=$(fn_tmux_pane_idx)
  local pane="${3:-$default_pane}"
  tmux split-window -v -t "${session}:${win}.${pane}"
}

# -----------------------------------------------------------------------------
# Convenience: window creation + first command
# -----------------------------------------------------------------------------

fn_tmux_window_create_and_run() {
  # Create a new window (if needed), then run a command in its first pane.
  # This is the most common pattern for adding a service window.
  #
  # Usage: fn_tmux_window_create_and_run <session> <window_name> <command>
  local session="${1:?session required}"
  local win="${2:?window required}"
  local cmd="${3:?command required}"
  fn_tmux_window_new "$session" "$win"
  fn_tmux_pane_run "$session" "$win" "" "$cmd"
}

fn_tmux_window_create_and_run_bash() {
  # Create a new window (if needed), then run a bash script in its first pane.
  #
  # Usage: fn_tmux_window_create_and_run_bash <session> <window_name> <script_string>
  local session="${1:?session required}"
  local win="${2:?window required}"
  local script="${3:?script required}"
  fn_tmux_window_new "$session" "$win"
  fn_tmux_pane_run_bash "$session" "$win" "" "$script"
}

# -----------------------------------------------------------------------------
# Session attach
# -----------------------------------------------------------------------------

fn_tmux_attach() {
  # Attach to an existing session.
  #
  # Usage: fn_tmux_attach <session_name>
  local session="${1:?session required}"
  tmux attach-session -t "$session"
}

# =============================================================================
# Backwards compatibility aliases (deprecated)
# =============================================================================
# Old API (window-index based) is retained for existing simple scripts,
# but new multi-window scripts should use the named-window API above.

fn_tmux_run() {
  # DEPRECATED: use fn_tmux_pane_run or fn_tmux_window_create_and_run
  # Kept for scripts that only use a single window (base-index model).
  local session="${1:-main}"
  local pane="${2:-1}"
  shift 2
  local win
  win=$(fn_tmux_win_idx)
  tmux send-keys -t "$session:${win}.$pane" "$*" Enter
}

fn_tmux_run_bash() {
  # DEPRECATED: use fn_tmux_pane_run_bash
  local session="${1:-main}"
  local pane="${2:-1}"
  local script="${3:-}"
  local command=""
  printf -v command 'bash -lc %q' "$script"
  fn_tmux_run "$session" "$pane" "$command"
}

fn_tmux_split_h() {
  # DEPRECATED wrapper: delegates to fn_tmux_split_h with base-index
  local session="${1:-main}"
  local pane="${2:-1}"
  local win
  win=$(fn_tmux_win_idx)
  tmux split-window -h -t "$session:${win}.$pane"
}

fn_tmux_split_v() {
  # DEPRECATED wrapper: delegates to fn_tmux_split_v with base-index
  local session="${1:-main}"
  local pane="${2:-1}"
  local win
  win=$(fn_tmux_win_idx)
  tmux split-window -v -t "$session:${win}.$pane"
}
