#!/usr/bin/env bash
#
# Restart Syncthing on host and device
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SERVICE_DIR="$(dirname "${SCRIPT_DIR}")/sync_service"
source "${SYNC_SERVICE_DIR}/common.sh"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# Load device configuration
fn_nv_load_env

restart_host() {
    log_info "Restarting Syncthing on host..."
    
    if ! systemctl --user is-active --quiet syncthing.service; then
        log_warn "Syncthing is not running on host"
    fi
    
    systemctl --user restart syncthing.service
    sleep 2
    
    if systemctl --user is-active --quiet syncthing.service; then
        log_info "Host Syncthing restarted successfully"
        systemctl --user status syncthing.service --no-pager -n 5
    else
        log_error "Host Syncthing failed to restart"
        systemctl --user status syncthing.service --no-pager -n 10
        return 1
    fi
}

restart_device() {
    log_info "Restarting Syncthing on device (${DEVICE_USER}@${DEVICE_IP})..."
    
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    
    # Check if syncthing is running on device
    if ! "${SSH_CMD[@]}" "systemctl --user is-active --quiet syncthing.service"; then
        log_warn "Syncthing is not running on device"
    fi
    
    # Restart syncthing on device
    "${SSH_CMD[@]}" "systemctl --user restart syncthing.service"
    sleep 2
    
    # Check status
    if "${SSH_CMD[@]}" "systemctl --user is-active --quiet syncthing.service"; then
        log_info "Device Syncthing restarted successfully"
        "${SSH_CMD[@]}" "systemctl --user status syncthing.service --no-pager -n 5"
    else
        log_error "Device Syncthing failed to restart"
        "${SSH_CMD[@]}" "systemctl --user status syncthing.service --no-pager -n 10"
        return 1
    fi
}

main() {
    echo "=========================================="
    echo "Restarting Syncthing Services"
    echo "=========================================="
    echo ""
    
    restart_host
    echo ""
    restart_device
    echo ""
    log_info "Syncthing restart complete"
}

main "$@"
