#!/usr/bin/env bash

AUTO_HOVER_RED='\033[0;31m'
AUTO_HOVER_GREEN='\033[0;32m'
AUTO_HOVER_YELLOW='\033[1;33m'
AUTO_HOVER_BLUE='\033[0;34m'
AUTO_HOVER_NC='\033[0m'

log_info() { echo -e "${AUTO_HOVER_GREEN}[INFO]${AUTO_HOVER_NC} $1"; }
log_warn() { echo -e "${AUTO_HOVER_YELLOW}[WARN]${AUTO_HOVER_NC} $1"; }
log_error() { echo -e "${AUTO_HOVER_RED}[ERROR]${AUTO_HOVER_NC} $1"; }
log_step() { echo -e "${AUTO_HOVER_BLUE}[STEP]${AUTO_HOVER_NC} $1"; }

check_hover_dependencies() {
    local serial_port="$1"
    local missing=()

    log_step "Checking dependencies..."

    command -v tmux >/dev/null 2>&1 || missing+=("tmux")
    command -v roslaunch >/dev/null 2>&1 || missing+=("roslaunch")
    command -v rostopic >/dev/null 2>&1 || missing+=("rostopic")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Run: source /opt/ros/noetic/setup.bash"
        return 1
    fi

    if [[ ! -e "$serial_port" ]]; then
        log_error "Serial port not found: $serial_port"
        return 1
    fi

    if [[ ! -r "$serial_port" ]]; then
        log_step "Setting permissions for $serial_port"
        sudo chmod 666 "$serial_port" || {
            log_error "Failed to set permissions for $serial_port"
            return 1
        }
    fi

    log_info "Dependencies OK"
}

wait_for_topic() {
    local topic_pattern="$1"
    local description="$2"
    local timeout="${3:-${TOPIC_WAIT_TIMEOUT:-30}}"
    local interval="${4:-0.5}"
    local deadline=$((SECONDS + timeout))

    log_step "Waiting for $description (timeout: ${timeout}s)..."

    while (( SECONDS < deadline )); do
        local matched
        matched=$(rostopic list 2>/dev/null | grep -m1 "$topic_pattern") || true
        if [[ -n "$matched" ]]; then
            echo "$matched"
            log_info "$description ready"
            return 0
        fi
        sleep "$interval"
    done

    log_error "Timeout waiting for $description (pattern: $topic_pattern)"
    return 1
}

wait_for_topics() {
    local timeout="$1"
    shift
    local topic_pattern=""
    local description=""

    while [[ $# -gt 0 ]]; do
        topic_pattern="$1"
        description="$2"
        wait_for_topic "$topic_pattern" "$description" "$timeout" || return 1
        shift 2
    done
}
