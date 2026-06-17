#!/usr/bin/env bash
#
# Pre-flight environment check for yopo-viz-bringup.
# Verifies all prerequisites on the devel machine before attempting
# a YOPO Docker RViz session.
#
# Usage:
#   bash .agents/skills/yopo-viz-bringup/check_env.sh
#
# Exit codes:
#   0  All checks passed.
#   1  One or more prerequisite(s) missing.
set -euo pipefail

readonly R='\033[0;31m'
readonly G='\033[0;32m'
readonly Y='\033[0;33m'
readonly B='\033[0;34m'
readonly N='\033[0m'

NC=0
fct_pass() { printf "${G}[PASS]${N} %s\n" "$1"; }
ct_fail() { printf "${R}[FAIL]${N} %s\n" "$1"; NC=1; }
fct_skip() { printf "${Y}[SKIP]${N} %s\n" "$1"; }
fct_info() { printf "${B}[INFO]${N} %s\n" "$1"; }

fct_check_docker() {
    if command -v docker >/dev/null 2>&1; then
        fct_pass "Docker: $(docker --version 2>/dev/null)"
    else
        ct_fail "Docker not found"
        return
    fi
    if docker compose version >/dev/null 2>&1; then
        fct_pass "Docker Compose: $(docker compose version 2>/dev/null)"
    else
        ct_fail "Docker Compose plugin not found"
    fi
}

fct_check_nvidia() {
    if ! nvidia-smi >/dev/null 2>&1; then
        ct_fail "nvidia-smi failed - no NVIDIA GPU or driver issue"
        return
    fi
    fct_pass "nvidia-smi: OK"
    if command -v nvidia-container-toolkit >/dev/null 2>&1; then
        fct_pass "nvidia-container-toolkit: $(nvidia-container-toolkit --version 2>/dev/null | head -1)"
    else
        ct_fail "nvidia-container-toolkit not found (needed for GPU passthrough)"
        return
    fi
    if docker info 2>/dev/null | grep -q "nvidia.*runc"; then
        fct_pass "Docker daemon nvidia runtime configured"
    else
        ct_fail "nvidia runtime not registered in docker daemon"
    fi
}

fct_check_noetic_image() {
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q 'osrf/ros:noetic-desktop-full'; then
        fct_pass "Image osrf/ros:noetic-desktop-full present"
    else
        fct_info "Image osrf/ros:noetic-desktop-full not found locally"
        fct_info "  Pull: docker pull osrf/ros:noetic-desktop-full"
    fi
}

fct_check_gpu_docker() {
    if ! docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q 'osrf/ros:noetic-desktop-full'; then
        fct_skip "GPU docker test skipped (image not pulled)"
        return
    fi
    if docker run --rm --gpus all osrf/ros:noetic-desktop-full \
        nvidia-smi >/dev/null 2>&1; then
        fct_pass "GPU docker: container can access GPU"
    else
        ct_fail "GPU docker: nvidia-smi inside container failed"
        fct_info "  Try: docker run --rm --gpus all osrf/ros:noetic-desktop-full nvidia-smi"
    fi
}

fct_check_x11() {
    if [[ -z "${DISPLAY:-}" ]]; then
        ct_fail "DISPLAY not set"
        return
    fi
    fct_pass "DISPLAY=${DISPLAY}"
    if xhost >/dev/null 2>&1; then
        if xhost 2>/dev/null | grep -q "SI:localuser:root\|LOCAL\|+"; then
            fct_pass "xhost: root authorized or access unrestricted"
        else
            fct_info "xhost: root may need authorization"
            fct_info "  Run: xhost +SI:localuser:root"
        fi
    else
        fct_info "xhost not available (Wayland?)"
        fct_info "  Docker X11 may need additional config: echo \$XDG_SESSION_TYPE"
    fi
    if [[ -f "${XAUTHORITY:-${HOME}/.Xauthority}" ]]; then
        fct_pass "Xauthority file present"
    else
        fct_info "Xauthority file not found at ${XAUTHORITY:-${HOME}/.Xauthority}"
    fi
}

fct_check_jetson() {
    local host="${REMOTE_HOST:-192.168.55.1}"
    if ping -c1 -W2 "$host" >/dev/null 2>&1; then
        fct_pass "Jetson reachable at $host"
    else
        ct_fail "Jetson unreachable at $host"
        fct_info "  Check USB cable and IP: ip route get $host"
        return
    fi
    if command -v sshpass >/dev/null 2>&1; then
        fct_pass "sshpass available"
    else
        fct_info "sshpass not found (set up SSH keys or provide password via SSHPASS)"
    fi
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR \
        "nv@${host}" "echo OK" 2>/dev/null; then
        fct_pass "SSH to nv@${host}: OK"
    else
        ct_fail "SSH to nv@${host} failed"
        fct_info "  Check SSHPASS env var or SSH key setup"
    fi
}

fct_check_workspace() {
    local wspath="${C5PRO_DIR:-$PWD}"
    if [[ -f "${wspath}/pyproject.toml" ]]; then
        fct_pass "Workspace root found: ${wspath}"
    else
        ct_fail "Not inside c5pro workspace (no pyproject.toml)"
        return
    fi
    local yopi_pkg="${wspath}/deploy-side/src/control/yopo_inference"
    if [[ -d "${yopi_pkg}/scripts" ]] && [[ -d "${yopi_pkg}/launch" ]]; then
        fct_pass "yopo_inference package found"
    else
        ct_fail "yopo_inference package missing at ${yopi_pkg}"
    fi
}

fct_main() {
    printf "=== YOPO Viz Bringup: Environment Check ===\n\n"
    fct_check_docker
    echo
    fct_check_nvidia
    echo
    fct_check_noetic_image
    fct_check_gpu_docker
    echo
    fct_check_x11
    echo
    fct_check_jetson
    echo
    fct_check_workspace
    echo
    if [[ $NC -eq 0 ]]; then
        printf "${G}=== All checks passed ===${N}\n"
    else
        printf "${R}=== One or more checks FAILED ===${N}\n"
        printf "${Y}Review failures above before running 'uv run viz yopo'${N}\n"
    fi
    exit "$NC"
}

fct_main "$@"
