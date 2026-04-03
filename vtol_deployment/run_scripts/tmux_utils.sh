#!/usr/bin/env bash

fn_tmux_session_start() {
  local session="${1:-main}"
  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" -x 200 -y 50 -n main
}

fn_tmux_run() {
  local session="${1:-main}"
  local pane="${2:-0}"
  shift 2
  tmux send-keys -t "$session:0.$pane" "$*" Enter
}

fn_tmux_run_bash() {
  local session="${1:-main}"
  local pane="${2:-0}"
  local script="${3:-}"
  local command=""

  printf -v command 'bash -lc %q' "$script"
  fn_tmux_run "$session" "$pane" "$command"
}

fn_tmux_split_h() {
  local session="${1:-main}"
  local pane="${2:-0}"
  tmux split-window -h -t "$session:0.$pane"
}

fn_tmux_split_v() {
  local session="${1:-main}"
  local pane="${2:-0}"
  tmux split-window -v -t "$session:0.$pane"
}

fn_tmux_attach() {
  local session="${1:-main}"
  tmux attach-session -t "$session"
}
