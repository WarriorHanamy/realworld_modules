#!/usr/bin/env bash
set -eo pipefail

fn_tmux_win_idx() {
  tmux show-option -g base-index 2>/dev/null | awk '{print $NF}'
}

fn_tmux_session_start() {
  local session="${1:-main}"
  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" -x 200 -y 50 -n main
}

fn_tmux_run() {
  local session="${1:-main}"
  local pane="${2:-1}"
  shift 2
  local win
  win=$(fn_tmux_win_idx)
  tmux send-keys -t "$session:${win}.$pane" "$*" Enter
}

fn_tmux_run_bash() {
  local session="${1:-main}"
  local pane="${2:-1}"
  local script="${3:-}"
  local command=""

  printf -v command 'bash -lc %q' "$script"
  fn_tmux_run "$session" "$pane" "$command"
}

fn_tmux_split_h() {
  local session="${1:-main}"
  local pane="${2:-1}"
  local win
  win=$(fn_tmux_win_idx)
  tmux split-window -h -t "$session:${win}.$pane"
}

fn_tmux_split_v() {
  local session="${1:-main}"
  local pane="${2:-1}"
  local win
  win=$(fn_tmux_win_idx)
  tmux split-window -v -t "$session:${win}.$pane"
}

fn_tmux_attach() {
  local session="${1:-main}"
  tmux attach-session -t "$session"
}
