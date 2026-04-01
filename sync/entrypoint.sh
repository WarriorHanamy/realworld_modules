#!/usr/bin/env bash
#
# Sync module entrypoint
# Manages Syncthing-based bidirectional sync between host and Jetson device
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
Usage: $(basename "$0") <command> [OPTIONS]

Commands:
  setup     Setup Syncthing bidirectional sync (host <-> device)
  wait      Wait for Syncthing folder sync to complete
  exec      Run remote command on device (catkin-make / run-vio)
  ssh-key   Copy SSH key to device
  sudoer    Enable passwordless sudo on device

Run '$(basename "$0") <command> --help' for command-specific options.
EOF
}

cmd_setup() {
    exec "${SCRIPT_DIR}/setup-syncthing.sh" "$@"
}

cmd_wait() {
    exec "${SCRIPT_DIR}/syncthing-wait.sh" "$@"
}

cmd_exec() {
    exec "${SCRIPT_DIR}/remote-exec.sh" "$@"
}

cmd_ssh_key() {
    exec "${SCRIPT_DIR}/copy_ssh_key.sh" "$@"
}

cmd_sudoer() {
    exec "${SCRIPT_DIR}/raise_sudoer.sh" "$@"
}

main() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    local command="$1"
    shift

    case "$command" in
        setup)
            cmd_setup "$@"
            ;;
        wait)
            cmd_wait "$@"
            ;;
        exec)
            cmd_exec "$@"
            ;;
        ssh-key)
            cmd_ssh_key "$@"
            ;;
        sudoer)
            cmd_sudoer "$@"
            ;;
        -h|--help|help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown command: ${command}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
