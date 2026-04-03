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
GCS_URL="${GCS_URL:-udp://@192.168.110.229:14550}"
VINS_WS="${VINS_WS:-/home/nv/Fast-Drone-250-master}"
AREC_WS="${AREC_WS:-/home/nv/arec_bags}"
TOPIC_WAIT_TIMEOUT="${TOPIC_WAIT_TIMEOUT:-30}"
ROS_SETUP="${ROS_SETUP:-/opt/ros/noetic/setup.bash}"
REALSENSE_LAUNCH_ARGS="${REALSENSE_LAUNCH_ARGS:-infra_width:=640 infra_height:=480 enable_infra1:=true enable_infra2:=true enable_depth:=true enable_color:=false}"
VINS_LAUNCH_FILE="${VINS_LAUNCH_FILE:-fast_drone_250.launch}"
ODOM_INPUT_TOPIC="${ODOM_INPUT_TOPIC:-/vins_fusion/imu_propagate}"
MAVROS_STATE_PATTERN="${MAVROS_STATE_PATTERN:-/mavros/imu/data}"
CAMERA_TOPIC_PATTERN="${CAMERA_TOPIC_PATTERN:-camera}"
MAVCMD_ATTITUDE_RATE="${MAVCMD_ATTITUDE_RATE:-5000}"
MAVCMD_HIGHRES_IMU_RATE="${MAVCMD_HIGHRES_IMU_RATE:-4000}"
MAVCMD_ODOM_RATE="${MAVCMD_ODOM_RATE:-20000}"
MAVCMD_VISION_RATE="${MAVCMD_VISION_RATE:-10000}"
MAVCMD_VISION_RATE_SLOW="${MAVCMD_VISION_RATE_SLOW:-5000}"
COMMON_SH="${SCRIPT_DIR}/auto_hover_common.sh"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Start VIO-based auto-hover system with mavros, realsense, vins, and odom bridge.

Options:
    -h, --help          Show this help message
    -n, --no-attach     Don't attach to tmux session after startup
    --session NAME      Tmux session name (default: auto_hover)
    --serial PORT       Serial port device (default: /dev/ttyTHS0)
    --baudrate RATE     Serial baudrate (default: 921600)
    --gcs-url URL       GCS URL for mavros (default: udp://@192.168.110.229:14550)

Environment Variables:
    SESSION             Tmux session name
    SERIAL_PORT         Serial port device
    BAUDRATE            Serial baudrate
    GCS_URL             GCS URL
    ROS_SETUP           ROS setup script path
    VINS_WS             VINS workspace path (default: /home/nv/Fast-Drone-250-master)
    AREC_WS             AREC workspace path (default: /home/nv/arec_bags)
    TOPIC_WAIT_TIMEOUT  Timeout in seconds for topic waits (default: 30)
    ODOM_INPUT_TOPIC    Input odometry topic for bridge

Panes:
    0: mavros (PX4 communication)
    1: realsense (camera)
    2: vins (visual-inertial odometry)
    3: odom_bridge (vio to mavros)

Examples:
    $(basename "$0")              # Start system and attach to tmux
    $(basename "$0") --no-attach  # Start system, don't attach
    $(basename "$0") --session test_hover
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

build_realsense_script() {
    cat <<EOF
source "${COMMON_SH}"
source "${ROS_SETUP}"
source "${VINS_WS}/devel/setup.bash"
exec roslaunch realsense2_camera rs_camera.launch ${REALSENSE_LAUNCH_ARGS}
EOF
}

build_vins_script() {
    cat <<EOF
$(build_wait_helpers)
source "${ROS_SETUP}"
source "${VINS_WS}/devel/setup.bash"
wait_for_topics "${TOPIC_WAIT_TIMEOUT}" \
    "${MAVROS_STATE_PATTERN}" "mavros state topic" \
    "${CAMERA_TOPIC_PATTERN}" "camera topic"
exec roslaunch vins ${VINS_LAUNCH_FILE}
EOF
}

build_odom_bridge_script() {
    cat <<EOF
$(build_wait_helpers)
source "${ROS_SETUP}"
source "${AREC_WS}/simple_px4_odom/devel/setup.bash"
wait_for_topic "${ODOM_INPUT_TOPIC}" "VINS odometry topic" "${TOPIC_WAIT_TIMEOUT}"
exec roslaunch simple_px4_odom vio_to_mavros_odom.launch input_odom:=${ODOM_INPUT_TOPIC}
EOF
}

start_system() {
    log_step "Starting VIO auto-hover system..."
    
    fn_tmux_session_start "$SESSION"
    
    fn_tmux_split_h "$SESSION" 0
    fn_tmux_split_v "$SESSION" 0
    fn_tmux_split_v "$SESSION" 1
    
    run_pane_script 0 "mavros" "$(build_mavros_script)"
    run_pane_script 1 "realsense camera" "$(build_realsense_script)"
    run_pane_script 2 "vins" "$(build_vins_script)"
    run_pane_script 3 "odom_bridge" "$(build_odom_bridge_script)"
    
    log_info "System started in tmux session: $SESSION"
}

print_status() {
    echo ""
    echo "=========================================="
    echo -e "${AUTO_HOVER_GREEN}VIO Auto-Hover System Started${AUTO_HOVER_NC}"
    echo "=========================================="
    echo ""
    echo "Session: $SESSION"
    echo ""
    echo "Panes:"
    echo "  0: mavros    (PX4 communication)"
    echo "  1: realsense (camera)"
    echo "  2: vins      (visual-inertial odometry)"
    echo "  3: odom_bridge (vio to mavros)"
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
