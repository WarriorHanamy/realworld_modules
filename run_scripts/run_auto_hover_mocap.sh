#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/auto_hover_common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux_utils.sh"

SESSION="${SESSION:-auto_hover}"
SERIAL_PORT="${SERIAL_PORT:-/dev/ttyTHS0}"
BAUDRATE="${BAUDRATE:-921600}"
GCS_URL="${GCS_URL:-udp://@10.1.1.17:14550}"
VRPN_SERVER="${VRPN_SERVER:-10.1.1.198}"
AREC_WS="${AREC_WS:-/home/nv/arec_bags}"
TOPIC_WAIT_TIMEOUT="${TOPIC_WAIT_TIMEOUT:-30}"
ROS_SETUP="${ROS_SETUP:-/opt/ros/noetic/setup.bash}"
ODOM_INPUT_POSE="${ODOM_INPUT_POSE:-/vrpn_client_node/zuanfeng/pose}"
VRPN_TOPIC_PATTERN="${VRPN_TOPIC_PATTERN:-vrpn_client_node}"
MAVCMD_ATTITUDE_RATE="${MAVCMD_ATTITUDE_RATE:-5000}"
MAVCMD_HIGHRES_IMU_RATE="${MAVCMD_HIGHRES_IMU_RATE:-5000}"
MAVCMD_ODOM_RATE="${MAVCMD_ODOM_RATE:-20000}"
MAVCMD_VISION_RATE="${MAVCMD_VISION_RATE:-10000}"
MAVCMD_VISION_RATE_SLOW="${MAVCMD_VISION_RATE_SLOW:-5000}"
COMMON_SH="${SCRIPT_DIR}/auto_hover_common.sh"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Start Mocap-based auto-hover system with mavros and vrpn.

Options:
    -h, --help          Show this help message
    -n, --no-attach     Don't attach to tmux session after startup
    --session NAME      Tmux session name (default: auto_hover)
    --serial PORT       Serial port device (default: /dev/ttyTHS0)
    --baudrate RATE     Serial baudrate (default: 921600)
    --gcs-url URL       GCS URL for mavros (default: udp://@192.168.110.229:14550)
    --vrpn-server IP    VRPN server IP (default: 10.1.1.198)

Environment Variables:
    SESSION             Tmux session name
    SERIAL_PORT         Serial port device
    BAUDRATE            Serial baudrate
    GCS_URL             GCS URL
    VRPN_SERVER         VRPN server IP
    ROS_SETUP           ROS setup script path
    AREC_WS             AREC workspace path (default: /home/nv/arec_bags)
    TOPIC_WAIT_TIMEOUT  Timeout in seconds for topic waits (default: 30)
    ODOM_INPUT_POSE     Input pose topic for bridge

Panes:
    0: mavros (PX4 communication)
    1: vrpn (motion capture)
    2: odom_bridge (mocap to mavros)

Examples:
    $(basename "$0")              # Start system and attach to tmux
    $(basename "$0") --no-attach  # Start system, don't attach
    $(basename "$0") --vrpn-server 10.1.1.100
EOF
}

check_dependencies() {
    check_hover_dependencies "$SERIAL_PORT" || exit 1
}

build_wait_helpers() {
    cat <<EOF
source "${COMMON_SH}"
EOF
}

run_pane_script() {
    local pane="$1"
    local title="$2"
    local script="$3"

    log_info "Pane ${pane}: ${title}"
    fn_tmux_run_bash "$SESSION" "$pane" "$script"
}

build_mavros_script() {
    cat <<EOF
source "${COMMON_SH}"
source "${ROS_SETUP}"
roslaunch mavros px4.launch fcu_url:='${SERIAL_PORT}:${BAUDRATE}' gcs_url:='${GCS_URL}' &
roslaunch_pid=\$!
sleep 5
rosrun mavros mavcmd long 511 31 ${MAVCMD_ATTITUDE_RATE} 0 0 0 0 0
sleep 1
rosrun mavros mavcmd long 511 105 ${MAVCMD_HIGHRES_IMU_RATE} 0 0 0 0 0
sleep 1
rosrun mavros mavcmd long 511 106 ${MAVCMD_ODOM_RATE} 0 0 0 0 0
sleep 1
rosrun mavros mavcmd long 511 147 ${MAVCMD_VISION_RATE} 0 0 0 0 0
sleep 1
rosrun mavros mavcmd long 511 147 ${MAVCMD_VISION_RATE_SLOW} 0 0 0 0 0
wait "\${roslaunch_pid}"
EOF
}

build_vrpn_script() {
    cat <<EOF
source "${COMMON_SH}"
source "${ROS_SETUP}"
sleep 5
exec roslaunch vrpn_client_ros sample.launch server:=${VRPN_SERVER}
EOF
}

build_odom_bridge_script() {
    cat <<EOF
$(build_wait_helpers)
source "${ROS_SETUP}"
source "${AREC_WS}/simple_px4_odom/devel/setup.bash"
sleep 8
wait_for_topic "${VRPN_TOPIC_PATTERN}" "VRPN topic" "${TOPIC_WAIT_TIMEOUT}"
exec roslaunch simple_px4_odom mocap_to_mavros_odom.launch input_pose:=${ODOM_INPUT_POSE}
EOF
}

start_system() {
    log_step "Starting Mocap auto-hover system..."
    
    fn_tmux_session_start "$SESSION"
    
    fn_tmux_split_h "$SESSION" 0
    fn_tmux_split_v "$SESSION" 1
    
    run_pane_script 0 "mavros" "$(build_mavros_script)"
    run_pane_script 1 "vrpn client" "$(build_vrpn_script)"
    run_pane_script 2 "odom_bridge" "$(build_odom_bridge_script)"
    
    log_info "System started in tmux session: $SESSION"
}

print_status() {
    echo ""
    echo "=========================================="
    echo -e "${AUTO_HOVER_GREEN}Mocap Auto-Hover System Started${AUTO_HOVER_NC}"
    echo "=========================================="
    echo ""
    echo "Session: $SESSION"
    echo "VRPN Server: $VRPN_SERVER"
    echo ""
    echo "Panes:"
    echo "  0: mavros      (PX4 communication)"
    echo "  1: vrpn        (motion capture)"
    echo "  2: odom_bridge (mocap to mavros)"
    echo ""
    echo "Commands:"
    echo "  Attach:  tmux attach -t $SESSION"
    echo "  Stop:    tmux kill-session -t $SESSION"
    echo "  Select:  tmux select-pane -t $SESSION:0.<pane>"
    echo ""
}

main() {
    local should_attach=1
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -n|--no-attach)
                should_attach=0
                shift
                ;;
            --session)
                SESSION="$2"
                shift 2
                ;;
            --serial)
                SERIAL_PORT="$2"
                shift 2
                ;;
            --baudrate)
                BAUDRATE="$2"
                shift 2
                ;;
            --gcs-url)
                GCS_URL="$2"
                shift 2
                ;;
            --vrpn-server)
                VRPN_SERVER="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    check_dependencies
    start_system
    print_status
    
    if [[ $should_attach -eq 1 ]]; then
        log_info "Attaching to tmux session..."
        fn_tmux_attach "$SESSION"
    fi
}

main "$@"
