#!/usr/bin/env bash
#
# yopo_viz_bringup.sh — phased YOPO visualization bringup with per-step
# health checks on the devel machine.
#
# Orchestrates Jetson-side ROS components (LiDAR/SLAM → EKF → YOPO preproc)
# and host-side Docker RViz in 4 sequential phases, each verified by topic
# data availability before proceeding to the next.
#
# Usage:
#   bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh
#   bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --mode full
#   bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --bag /path/on/jetson/your.bag
#   bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --skip-check
#   bash .agents/skills/yopo-viz-bringup/yopo_viz_bringup.sh --help
#
# Arguments:
#   --bag <path>       Rosbag replay mode (path is on Jetson filesystem)
#   --mode <name>      YOPO mode: preproc (default) or full (C5-lidar-yopo)
#   --skip-check       Skip pre-flight environment check
#   --skip-env-clean   Skip cleanup of previous tmux/Docker sessions
#   --verbose          More detailed output
#   --help             Show this help
#
# Exit codes:
#   0  Success (RViz closed normally)
#   1  Pre-flight check failed
#   2  Phase 1 (LiDAR+SLAM) failed
#   3  Phase 2 (EKF) failed
#   4  Phase 3 (YOPO) failed
#   5  Phase 4 (Docker/RViz) failed
#   6  Unexpected error / interrupt
#
# Environment variables:
#   REMOTE_HOST       Jetson IP (default: 192.168.55.1)
#   REMOTE_PATH       Jetson workspace path (default: /home/nv/ros1-yopo)
#   SSHPASS           Password for SSH (used when SSH keys not set up)
#   SSH_OPTS          Extra SSH options
#   DOCKER_CONTAINER  Container name override
#
# Prerequisites (checked in pre-flight):
#   - Docker + compose
#   - nvidia-container-toolkit (for GPU passthrough)
#   - osrf/ros:noetic-desktop-full image
#   - X11 display
#   - Jetson reachable at REMOTE_HOST
#   - yopo_inference ROS package on Jetson
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly DOCKER_COMPOSE_FILE="${REPO_ROOT}/docker/deploy.compose.rviz.yml"

REMOTE_HOST="${REMOTE_HOST:-192.168.55.1}"
REMOTE_PATH="${REMOTE_PATH:-/home/nv/ros1-yopo}"
OLD_REPO_PATH="${OLD_REPO_PATH:-/home/nv/YOPO-C5Pro-Lidar}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR}"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-ros1-yopo-ros1-runtime-rviz}"
SESSION="ros1-yopo-yopo-viz-debug"

# Colors
readonly R='\033[0;31m'
readonly G='\033[0;32m'
readonly Y='\033[0;33m'
readonly B='\033[0;34m'
readonly C='\033[0;36m'
readonly N='\033[0m'

# Flags
BAG_PATH=""
SKIP_CHECK=false
SKIP_ENV_CLEAN=false
VERBOSE=false
YOPO_MODE="preproc"  # preproc or full
RVIZ_CONFIG="yopo_debug.rviz"

# Topic timeout per phase (seconds)
readonly PHASE1_TIMEOUT=60
readonly PHASE2_TIMEOUT=20
readonly PHASE3_TIMEOUT=25
readonly PHASE3_FULL_TIMEOUT=45

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
fct_prefix()     { printf "${C}[yopo-viz]${N} "; }
fct_info()       { fct_prefix >&2; printf "$1\n" >&2; }
fct_pass()       { printf "${G}  ✓${N} %s\n" "$1"; }
ct_fail()        { printf "${R}  ✗${N} %s\n" "$1"; }
fct_warn()       { printf "${Y}  ⚠${N} %s\n" "$1"; }
fct_verbose()    { [ "$VERBOSE" = true ] && fct_info "$@" || true; }

# ---------------------------------------------------------------------------
# SSH helper — wraps command in 'bash -c' for Jetson (zsh default shell)
# ---------------------------------------------------------------------------
fct_ssh() {
    # Usage: fct_ssh "<command>"
    # Encodes multi-line cmd as base64 to avoid quoting issues with zsh default
    # shell on Jetson. Decodes and pipes to bash on the remote side.
    local cmd="$1" encoded
    encoded=$(printf '%s' "$cmd" | base64 -w0 2>/dev/null || printf '%s' "$cmd" | base64)
    ssh -n ${SSH_OPTS} "nv@${REMOTE_HOST}" "echo ${encoded} | base64 -d | bash"
}

fct_ssh_bg() {
    # Like fct_ssh but background + detach (for long-running tmux starts)
    local cmd="$1" encoded
    encoded=$(printf '%s' "$cmd" | base64 -w0 2>/dev/null || printf '%s' "$cmd" | base64)
    ssh -f ${SSH_OPTS} "nv@${REMOTE_HOST}" \
        "echo ${encoded} | base64 -d | bash" > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Cleanup handler
# ---------------------------------------------------------------------------
fct_cleanup() {
    local exit_code=$?
    echo
    fct_info "Cleanup triggered (exit code $exit_code) ..."
    if [ "$exit_code" -eq 0 ]; then
        fct_info "RViz closed normally."
    else
        fct_warn "Interrupted or failed."
    fi
    cd "$REPO_ROOT"
    docker compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true
    fct_info "Docker container stopped."
    fct_info "Jetson tmux session still running (for debugging)."
    fct_info "  Kill: ssh nv@${REMOTE_HOST} \"bash ${REMOTE_PATH}/deploy-side/tmux_scripts/kill.sh\""
    exit "$exit_code"
}

fct_setup_trap() {
    trap fct_cleanup EXIT INT TERM
}

# ---------------------------------------------------------------------------
# Pre-flight environment check
# ---------------------------------------------------------------------------
fct_run_preflight() {
    fct_info "Pre-flight environment check ..."
    local check_script="${SCRIPT_DIR}/check_env.sh"
    if [ ! -x "$check_script" ]; then
        ct_fail "check_env.sh not found or not executable"
        exit 1
    fi
    if bash "$check_script"; then
        fct_pass "Pre-flight passed"
        echo
    else
        echo
        ct_fail "Pre-flight failed — fix issues above before retrying"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Docker container lifecycle
# ---------------------------------------------------------------------------
fct_docker_up() {
    fct_info "Starting Docker container ..."
    cd "$REPO_ROOT"

    # Authorize X11 for root
    if command -v xhost >/dev/null 2>&1; then
        xhost +SI:localuser:root >/dev/null 2>&1 || true
    fi

    # Ensure previous instance is stopped
    docker compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true

    local ros_master="http://${REMOTE_HOST}:11311"
    export ROS_MASTER_URI="$ros_master"
    export JETSON_IP="$REMOTE_HOST"

    docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    fct_pass "Container ${DOCKER_CONTAINER} started (ROS_MASTER_URI=${ros_master})"
}

fct_docker_down() {
    cd "$REPO_ROOT"
    docker compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true
}

fct_docker_exec() {
    # Run a ROS command inside the container (auto-sources setup.bash)
    local cmd="$1"
    docker exec "$DOCKER_CONTAINER" bash -c "source /opt/ros/noetic/setup.bash && $cmd" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Topic health check — poll until data appears on a ROS topic
# ---------------------------------------------------------------------------
fct_wait_topic() {
    local topic="$1" label="$2" timeout_s="$3"
    local waited=0 interval=2 dot_interval=10

    printf "${C}[yopo-viz]${N}   Waiting for ${label} (${topic}) ..."

    while [ $waited -lt $timeout_s ]; do
        # Capture output via $() instead of pipe to avoid SIGPIPE with pipefail.
        # Direct pipe (| head | grep) causes docker exec to receive EPIPE when
        # head/grep close early, and set -o pipefail turns the non-zero exit
        # into a FALSE condition for the if statement.
        local output
        output=$(fct_docker_exec "timeout 3 rostopic echo \"${topic}\" -n 1" 2>/dev/null) || true
        if [ -n "$output" ]; then
            local hz_line hz
            hz_line=$(fct_docker_exec "timeout 2 rostopic hz \"${topic}\" -w 1" 2>/dev/null) || true
            hz=$(echo "$hz_line" | grep -oP 'average rate: \K[\d.]+' | head -1 || echo "")
            if [ -n "$hz" ]; then
                printf "\r${C}[yopo-viz]${N}   ${G}✓${N} ${label} — publishing at ${hz} Hz\n"
            else
                printf "\r${C}[yopo-viz]${N}   ${G}✓${N} ${label} — online\n"
            fi
            return 0
        fi
        sleep "$interval"
        waited=$((waited + interval))
        [ $((waited % dot_interval)) -eq 0 ] && printf "." || true
    done

    printf "\r${C}[yopo-viz]${N}   ${R}✗${N} ${label} — no data after ${timeout_s}s\n"
    return 1
}

# ---------------------------------------------------------------------------
# Phase 1: LiDAR + SLAM
# ---------------------------------------------------------------------------
fct_phase1_lidar_slam() {
    fct_info "──────────────────────────────────────────────"
    fct_info "Phase 1/4: LiDAR + faster-LIO SLAM"
    echo

    # Create tmux session with first pane running lidar_launch
    fct_ssh_bg "
        cd ${REMOTE_PATH}
        tmux kill-session -t ${SESSION} 2>/dev/null || true
        tmux new-session -d -c ${REMOTE_PATH} -s ${SESSION} -n yopo \\
            'bash deploy-side/tmux_scripts/infra_scripts/lidar_launch.sh'
    "

    fct_wait_topic "/cloud_registered_body" "LiDAR+SLAM" "$PHASE1_TIMEOUT" || {
        ct_fail "LiDAR or faster-LIO not producing point cloud."
        echo "  Diagnose:"
        echo "    ssh nv@${REMOTE_HOST}"
        echo "    tmux attach -t ${SESSION}"
        echo "    Check pane 0 (lidar_launch.sh) for errors"
        echo "    Verify MID360 power & Ethernet (see lidar-debug skill)"
        echo "    Check faster_lio params: mid360.yaml on device"
        return 2
    }
    return 0
}

# ---------------------------------------------------------------------------
# Phase 2: EKF odometry
# ---------------------------------------------------------------------------
fct_phase2_ekf() {
    echo
    fct_info "──────────────────────────────────────────────"
    fct_info "Phase 2/4: EKF odometry"
    echo

    # Split horizontally to add ekf_launch pane
    fct_ssh_bg "
        cd ${REMOTE_PATH}
        tmux split-window -h -c ${REMOTE_PATH} -t ${SESSION}:yopo \\
            'bash deploy-side/tmux_scripts/infra_scripts/ekf_launch.sh'
    "

    fct_wait_topic "/ekf/ekf_odom" "EKF" "$PHASE2_TIMEOUT" || {
        ct_fail "EKF not publishing odometry."
        echo "  Diagnose:"
        echo "    ssh nv@${REMOTE_HOST}"
        echo "    tmux attach -t ${SESSION}"
        echo "    Check pane 1 (ekf_launch.sh) for errors"
        echo "    Verify IMU data: rostopic hz /livox/imu"
        return 3
    }
    return 0
}

# ---------------------------------------------------------------------------
# Phase 3: YOPO preprocessing
# ---------------------------------------------------------------------------
fct_phase3_yopo() {
    echo
    fct_info "──────────────────────────────────────────────"
    fct_info "Phase 3/4: YOPO preprocessing"
    echo

    # Split vertically under pane 0
    fct_ssh_bg "
        cd ${REMOTE_PATH}
        tmux split-window -v -c ${REMOTE_PATH} -t ${SESSION}:yopo.0 \\
            'bash deploy-side/tmux_scripts/infra_scripts/yopo_debug_launch.sh'
    "

    fct_wait_topic "/yopo_net/perspective_depth" "YOPO depth" "$PHASE3_TIMEOUT" || {
        ct_fail "YOPO preprocessing node not publishing."
        echo "  Diagnose:"
        echo "    ssh nv@${REMOTE_HOST}"
        echo "    tmux attach -t ${SESSION}"
        echo "    Check pane 2 (yopo_debug_launch.sh) for errors"
        echo "    Verify topic remap:"
        echo "      docker exec ${DOCKER_CONTAINER} bash -c 'source /opt/ros/noetic/setup.bash && rosparam get /yopo_lidar_preproc/lidar_topic'"
        echo "      Should be: /cloud_registered_body"
        return 4
    }

    # Show all detected yopo topics
    local yopo_topics
    yopo_topics=$(fct_docker_exec "rostopic list 2>/dev/null | grep yopo_net" | sort || true)
    if [ -n "$yopo_topics" ]; then
        local tcount
        tcount=$(echo "$yopo_topics" | wc -l)
        fct_pass "YOPO pipeline: $tcount topics detected"
        if [ "$VERBOSE" = true ]; then
            echo "$yopo_topics" | while IFS= read -r t; do
                echo "        ${t}"
            done
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Phase 3 (full inference mode): test_yopo_ros.py from C5-lidar-yopo repo
# ---------------------------------------------------------------------------
fct_phase3_yopo_full() {
    echo
    fct_info "──────────────────────────────────────────────"
    fct_info "Phase 3/4: YOPO full inference (C5-lidar-yopo)"
    echo

    # Use pre-created wrapper on Jetson (set up manually: run_yopo_full.sh
    # under OLD_REPO_PATH/YOPO/) that patches lidar_topic and sources the
    # correct ROS workspace before launching test_yopo_ros.py
    # Split pane 0 vertically for YOPO. Use single-line command to avoid
    # backslash-newline continuation loss in base64 SSH pipe mode.
    # Delegate YOPO pane creation to Jetson-side script (writing-tmux compliant:
    # no pane indices, relative navigation, window-level send-keys).
    fct_ssh_bg "cd ${REMOTE_PATH} && bash deploy-side/tmux_scripts/yopo_viz_full_bringup.sh --mode add-pane --no-rviz --headless"

    fct_wait_topic "/yopo_net/best_traj_visual" "YOPO full inference" "$PHASE3_FULL_TIMEOUT" || {
        ct_fail "YOPO full inference node not publishing trajectories."
        echo "  Diagnose:"
        echo "    ssh nv@${REMOTE_HOST}"
        echo "    tmux attach -t ${SESSION}"
        echo "    Check pane 2 (test_yopo_ros.py) for errors"
        echo "    Verify PyTorch model exists: ${OLD_REPO_PATH}/YOPO/saved/YOPO_1/epoch50.pth"
        echo "    Verify ROS workspace: ${OLD_REPO_PATH}/ros_ws/devel/setup.bash"
        echo "    Check topic remap in /tmp/run_yopo_full.sh"
        return 4
    }

    local full_topics
    full_topics=$(fct_docker_exec "rostopic list 2>/dev/null | grep -E 'yopo_net|setpoints_cmd'" | sort || true)
    if [ -n "$full_topics" ]; then
        local tcount
        tcount=$(echo "$full_topics" | wc -l)
        fct_pass "YOPO full inference: $tcount topics detected"
        if [ "$VERBOSE" = true ]; then
            echo "$full_topics" | while IFS= read -r t; do
                echo "        ${t}"
            done
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Phase 3 (bag mode variant): Start roscore + bag + yopo
# ---------------------------------------------------------------------------
fct_phase3_yopo_bag() {
    echo
    fct_info "──────────────────────────────────────────────"
    fct_info "Phase 3/4: YOPO preprocessing (rosbag replay)"
    echo
    fct_info "  Bag: ${BAG_PATH}"

    # Create tmux session with 3 panes:
    #   pane 0: roscore
    #   pane 1: yopo preproc (with sim_time)
    #   pane 2: rosbag play
    fct_ssh_bg "
        cd ${REMOTE_PATH}
        tmux kill-session -t ${SESSION} 2>/dev/null || true
        tmux new-session -d -c ${REMOTE_PATH} -s ${SESSION} -n yopo \\
            'printf \"=== ROSBAG REPLAY ===\nStarting roscore...\n\" && roscore'
    "

    # Wait a moment for roscore
    sleep 4

    fct_ssh_bg "
        cd ${REMOTE_PATH}
        tmux split-window -h -c ${REMOTE_PATH} -t ${SESSION}:yopo \\
            'sleep 2 && rosparam set /use_sim_time true && roslaunch yopo_inference yopo_preprocess_debug.launch'
        tmux split-window -v -c ${REMOTE_PATH} -t ${SESSION}:yopo.0 \\
            'sleep 4 && rosbag play --clock --loop ${BAG_PATH}'
    "

    fct_wait_topic "/yopo_net/perspective_depth" "YOPO depth" "$PHASE3_TIMEOUT" || {
        ct_fail "YOPO preprocessing node not publishing (bag mode)."
        echo "  Diagnose:"
        echo "    ssh nv@${REMOTE_HOST}"
        echo "    tmux attach -t ${SESSION}"
        echo "    Check pane 0 (roscore), pane 1 (yopo), pane 2 (rosbag)"
        echo "    Verify bag contains required topics:"
        echo "      rosbag info ${BAG_PATH} | grep -E 'cloud_registered_body|ekf_odom'"
        return 4
    }

    local yopo_topics
    yopo_topics=$(fct_docker_exec "rostopic list 2>/dev/null | grep yopo_net" | sort || true)
    if [ -n "$yopo_topics" ]; then
        local tcount
        tcount=$(echo "$yopo_topics" | wc -l)
        fct_pass "YOPO pipeline: $tcount topics detected (bag mode)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Phase 4: Docker RViz
# ---------------------------------------------------------------------------
fct_phase4_rviz() {
    echo
    fct_info "──────────────────────────────────────────────"
    fct_info "Phase 4/4: Docker RViz"
    echo

    # Arrange tmux panes in tiled layout
    fct_ssh_bg "
        tmux select-layout -t ${SESSION}:yopo tiled 2>/dev/null || true
    "

    fct_info "  Launching RViz (close window to stop)."
    fct_info "  Config: /rviz_configs/${RVIZ_CONFIG}"
    echo
    docker exec -i "$DOCKER_CONTAINER" bash -c \
        "source /opt/ros/noetic/setup.bash && rviz -d /rviz_configs/${RVIZ_CONFIG}" || {
        local rc=$?
        if [ $rc -eq 127 ]; then
            ct_fail "RViz not found in container (PATH issue)"
            echo "  Fix: docker exec -it ${DOCKER_CONTAINER}"
            echo "    bash -c 'source /opt/ros/noetic/setup.bash && rviz'"
            return 5
        fi
        return 5
    }
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
fct_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --bag|-b)
                BAG_PATH="$2"
                shift 2
                ;;
            --skip-check)
                SKIP_CHECK=true
                shift
                ;;
            --skip-env-clean)
                SKIP_ENV_CLEAN=true
                shift
                ;;
            --mode)
                local m="$2"
                if [ "$m" != "preproc" ] && [ "$m" != "full" ]; then
                    ct_fail "Unknown mode: $m (preproc|full)"
                    exit 1
                fi
                YOPO_MODE="$m"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                trap - EXIT INT TERM
                head -50 "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *)
                printf "${R}Unknown argument: %s${N}\n" "$1" >&2
                printf "Use --help for usage.\n" >&2
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main orchestration
# ---------------------------------------------------------------------------
fct_main() {
    fct_parse_args "$@"

    printf "\n${C}╔══════════════════════════════════════════╗${N}\n"
    printf "${C}║  YOPO Viz Bringup — Phased Orchestration ${N}\n"
    if [ -n "$BAG_PATH" ]; then
        printf "${C}║  Mode: Rosbag Replay                      ${N}\n"
    else
        printf "${C}║  Mode: %s                              ${N}\n" "$YOPO_MODE"
    fi
    printf "${C}╚══════════════════════════════════════════╝${N}\n"
    echo

    # Set RViz config per mode
    if [ "$YOPO_MODE" = "full" ]; then
        RVIZ_CONFIG="yopo_full_inference.rviz"
    else
        RVIZ_CONFIG="yopo_debug.rviz"
    fi

    # Step 0: Pre-flight
    if [ "$SKIP_CHECK" != true ]; then
        fct_run_preflight
    else
        fct_warn "Pre-flight check skipped (--skip-check)"
        echo
    fi

    # Step 1: Clean previous session on Jetson (if not skipped)
    if [ "$SKIP_ENV_CLEAN" != true ]; then
        fct_verbose "Cleaning previous tmux session on Jetson ..."
        fct_ssh "tmux kill-session -t ${SESSION} 2>/dev/null || true" 2>/dev/null || true
    fi

    # Step 2: Start Docker container (needed for topic health checks)
    fct_docker_up

    # Step 3: Run phases
    if [ -n "$BAG_PATH" ]; then
        # Bag mode: skip LiDAR+SLAM + EKF, do bag-based YOPO + RViz
        fct_phase3_yopo_bag
        local rc3=$?
        [ $rc3 -ne 0 ] && exit $rc3
    else
        # Live mode: LiDAR + EKF always needed
        fct_phase1_lidar_slam
        local rc1=$?
        [ $rc1 -ne 0 ] && exit $rc1

        fct_phase2_ekf
        local rc2=$?
        [ $rc2 -ne 0 ] && exit $rc2

        # Phase 3 depends on mode
        if [ "$YOPO_MODE" = "full" ]; then
            fct_phase3_yopo_full
        else
            fct_phase3_yopo
        fi
        local rc3=$?
        [ $rc3 -ne 0 ] && exit $rc3
    fi

    # Phase 4 always runs
    echo
    fct_pass "All components verified. Starting visualization."
    echo
    fct_phase4_rviz
    local rc4=$?
    [ $rc4 -ne 0 ] && exit $rc4

    # Normal exit — cleanup will run via trap
    echo
    fct_pass "Session complete."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
fct_setup_trap
fct_main "$@"
