#!/usr/bin/env bash
#
# Wait for Syncthing folder sync to complete
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEFAULT_TIMEOUT=60
DEFAULT_FOLDER_ID="zuanfeng-deploy"
DEFAULT_API_URL="http://localhost:8384"

TIMEOUT="${DEFAULT_TIMEOUT}"
FOLDER_ID="${DEFAULT_FOLDER_ID}"
API_URL="${DEFAULT_API_URL}"
POLL_INTERVAL=2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Wait for Syncthing folder sync to complete.

Options:
    -h, --help              Show this help message
    --timeout SECONDS       Maximum wait time (default: ${DEFAULT_TIMEOUT})
    --folder-id ID          Syncthing folder ID (default: ${DEFAULT_FOLDER_ID})
    --api-url URL           Syncthing API URL (default: ${DEFAULT_API_URL})
    --poll-interval SECS    Polling interval (default: 2)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --folder-id)
                FOLDER_ID="$2"
                shift 2
                ;;
            --api-url)
                API_URL="$2"
                shift 2
                ;;
            --poll-interval)
                POLL_INTERVAL="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

get_api_key() {
    local config_file="${HOME}/.config/syncthing/config.xml"
    if [[ ! -f "$config_file" ]]; then
        log_error "Syncthing config not found: $config_file"
        return 1
    fi
    
    grep -oP '(?<=<apikey>)[^<]+' "$config_file" | head -1
}

get_folder_status() {
    local api_key="$1"
    local url="${API_URL}/rest/db/status?folder=${FOLDER_ID}"
    
    curl -s -H "X-API-Key: ${api_key}" "$url" 2>/dev/null
}

wait_for_sync() {
    local api_key
    api_key=$(get_api_key)
    
    if [[ -z "$api_key" ]]; then
        log_error "Failed to get Syncthing API key"
        return 1
    fi
    
    local elapsed=0
    local last_state=""
    
    log_info "Waiting for Syncthing sync (folder: ${FOLDER_ID}, timeout: ${TIMEOUT}s)"
    
    while [[ $elapsed -lt $TIMEOUT ]]; do
        local status
        status=$(get_folder_status "$api_key")
        
        if [[ -z "$status" ]]; then
            log_warn "Failed to get folder status, retrying..."
            sleep "$POLL_INTERVAL"
            ((elapsed += POLL_INTERVAL))
            continue
        fi
        
        local state
        state=$(echo "$status" | grep -oP '(?<="state":")[^"]+' | head -1)
        
        if [[ "$state" != "$last_state" ]]; then
            log_info "Sync state: $state"
            last_state="$state"
        fi
        
        if [[ "$state" == "idle" ]]; then
            local need_bytes
            need_bytes=$(echo "$status" | grep -oP '(?<="needBytes":)[0-9]+' | head -1)
            
            if [[ "$need_bytes" == "0" ]]; then
                log_info "Sync complete"
                return 0
            fi
        fi
        
        sleep "$POLL_INTERVAL"
        ((elapsed += POLL_INTERVAL))
    done
    
    log_error "Sync wait timeout after ${TIMEOUT}s"
    return 1
}

main() {
    parse_args "$@"
    wait_for_sync
}

main "$@"
