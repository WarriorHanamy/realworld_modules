#!/usr/bin/env bash
#
# Remote execution wrapper for catkin_make and run_auto_hover_vio
# Offloads execution to target device via SSH, captures logs locally
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CMD_NAME=$(basename "$0")
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs"
DEVICE_WORKSPACE="/home/nv/arec_bags"
SYNC_TIMEOUT=60
CATKIN_PKG=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

setup_log_dirs() {
    mkdir -p "${LOG_DIR}/catkin" "${LOG_DIR}/tmux"
}

wait_for_sync() {
    log_step "Waiting for Syncthing sync..."
    if "${SCRIPT_DIR}/syncthing-wait.sh" --timeout "${SYNC_TIMEOUT}"; then
        log_info "Sync ready"
    else
        log_warn "Sync wait failed or timed out, proceeding anyway..."
    fi
}

ensure_remote_log_dirs() {
    fn_nv_ensure_ssh
    "${SSH_CMD[@]}" "mkdir -p ${DEVICE_WORKSPACE}/logs/catkin ${DEVICE_WORKSPACE}/logs/tmux"
}

remote_catkin_make() {
    local catkin_args=("$@")
    local log_file="${LOG_DIR}/catkin/$(date +%Y%m%d_%H%M%S).log"
    
    wait_for_sync
    ensure_remote_log_dirs
    
    fn_nv_ensure_ssh
    
    local build_dir="${DEVICE_WORKSPACE}"
    
    if [[ -n "${CATKIN_PKG}" ]]; then
        build_dir="${DEVICE_WORKSPACE}/${CATKIN_PKG}"
        log_step "Building package in-place: ${CATKIN_PKG}"
    fi
    
    log_step "Running catkin_make on ${DEVICE_USER}@${DEVICE_IP}..."
    log_info "Log file: ${log_file}"
    echo ""
    
    local catkin_cmd="bash -lc 'cd ${build_dir} && source /opt/ros/noetic/setup.bash && catkin_make ${catkin_args[*]:-}'"
    
    local exit_code=0
    "${SSH_CMD[@]}" "${catkin_cmd}" 2>&1 | tee "$log_file" || exit_code=$?
    
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log_info "catkin_make completed successfully"
    else
        log_error "catkin_make failed with exit code: ${exit_code}"
    fi
    
    return $exit_code
}

remote_run_vio() {
    local log_name="auto_hover_$(date +%Y%m%d_%H%M%S).log"
    local remote_log_file="${DEVICE_WORKSPACE}/logs/tmux/${log_name}"
    local local_log_file="${LOG_DIR}/tmux/${log_name}"
    
    wait_for_sync
    ensure_remote_log_dirs
    setup_log_dirs
    
    log_step "Starting VIO session on ${DEVICE_USER}@${DEVICE_IP}..."
    
    fn_nv_ensure_ssh
    
    local session_name="auto_hover"
    local script_path="${DEVICE_WORKSPACE}/thrust_calibration/run_auto_hover_vio.sh"
    
    "${SSH_CMD[@]}" "tmux kill-session -t ${session_name} 2>/dev/null || true"
    
    "${SSH_CMD[@]}" "tmux new-session -d -s ${session_name} -c ${DEVICE_WORKSPACE}/thrust_calibration -x 200 -y 50"
    
    "${SSH_CMD[@]}" "tmux pipe-pane -t ${session_name} -o \"cat >> ${remote_log_file}\""
    
    "${SSH_CMD[@]}" "tmux send-keys -t ${session_name} 'bash ${script_path}' Enter"
    
    sleep 1
    
    if "${SSH_CMD[@]}" "tmux has-session -t ${session_name} 2>/dev/null"; then
        log_info "Session '${session_name}' started successfully"
    else
        log_error "Failed to start session '${session_name}'"
        return 1
    fi
    
    touch "$local_log_file"
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}VIO Session Started${NC}"
    echo "=========================================="
    echo ""
    echo "Logs:"
    echo "  Remote: ${DEVICE_USER}@${DEVICE_IP}:${remote_log_file}"
    echo "  Local:  ${local_log_file} (synced via Syncthing)"
    echo ""
    echo "Commands:"
    echo "  Attach remote:  ssh ${DEVICE_USER}@${DEVICE_IP} -t 'tmux attach -t ${session_name}'"
    echo "  View logs:      tail -f ${local_log_file}"
    echo "  Stop session:   ssh ${DEVICE_USER}@${DEVICE_IP} 'tmux kill-session -t ${session_name}'"
    echo ""
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Remote execution wrapper. Invoke via symlink:
  remote-catkin-make [ARGS...]   - Run catkin_make on device
  remote-run-vio                 - Start VIO session on device

Options:
    -h, --help              Show this help message
    -p, --package NAME      Build specific catkin package (creates src/ symlink)
    --sync-timeout SECS     Syncthing sync timeout (default: ${SYNC_TIMEOUT})

Environment (from sync/.env):
    DEVICE_IP               Target device IP (default: 192.168.55.1)
    DEVICE_USER             Target device user (default: nv)
EOF
}

main() {
    local show_help_flag=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help_flag=1
                shift
                ;;
            -p|--package)
                CATKIN_PKG="$2"
                shift 2
                ;;
            --sync-timeout)
                SYNC_TIMEOUT="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done
    
    if [[ $show_help_flag -eq 1 ]]; then
        show_help
        exit 0
    fi
    
    setup_log_dirs
    fn_nv_load_env
    
    case "$CMD_NAME" in
        remote-catkin-make)
            remote_catkin_make "$@"
            ;;
        remote-run-vio)
            remote_run_vio "$@"
            ;;
        *)
            log_error "Unknown command: $CMD_NAME"
            log_info "Create symlink: ln -s remote-exec.sh remote-catkin-make"
            exit 1
            ;;
    esac
}

main "$@"
