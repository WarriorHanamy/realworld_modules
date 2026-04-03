#!/usr/bin/env bash
#
# ==============================================================================
# LiDAR-IMU Calibration Runner
# ==============================================================================
# One-click calibration: starts roscore, li_init node, plays rosbag, and copies
# the result. Designed to run inside the calib-lidar-imu-init Docker container.
# ==============================================================================

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

readonly DATA_DIR="/data"
readonly WS_DIR="/root/catkin_ws"
readonly RESULT_SRC="${WS_DIR}/src/LiDAR_IMU_Init/result/Initialization_result.txt"
readonly RESULT_DST="${DATA_DIR}/Initialization_result.txt"
readonly DEFAULT_LAUNCH="mid360.launch"

BAG_FILE=""
LAUNCH="${DEFAULT_LAUNCH}"
PLAY_RATE=""

fct_usage() {
	cat <<EOF
Usage: ${SCRIPT_NAME} [options] <bag_file>

Options:
  -h, --help          Show this help and exit
  -l, --launch NAME   ROS launch file (default: ${DEFAULT_LAUNCH})
  -r, --rate RATE     rosbag play rate (default: 1.0)

Arguments:
  bag_file            Path to rosbag file inside ${DATA_DIR}/

Examples:
  ${SCRIPT_NAME} calibration_data.bag
  ${SCRIPT_NAME} --rate 0.5 --launch livox_avia.launch calibration.bag
EOF
}

fct_parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			fct_usage
			exit 0
			;;
		-l | --launch)
			LAUNCH="${2}"
			shift 2
			;;
		-r | --rate)
			PLAY_RATE="${2}"
			shift 2
			;;
		--)
			shift
			if [[ $# -ge 1 ]]; then BAG_FILE="$1"; fi
			break
			;;
		-*)
			echo "Unknown option: $1" >&2
			fct_usage >&2
			exit 2
			;;
		*)
			BAG_FILE="$1"
			shift
			;;
		esac
	done

	if [[ -z "${BAG_FILE}" ]]; then
		echo "Error: bag_file is required" >&2
		fct_usage >&2
		exit 2
	fi
}

fct_validate_inputs() {
	if [[ ! -f "${BAG_FILE}" ]]; then
		echo "Error: bag file not found: ${BAG_FILE}" >&2
		exit 1
	fi

	if [[ ! -f "${WS_DIR}/devel/setup.bash" ]]; then
		echo "Error: catkin workspace not built: ${WS_DIR}/devel/setup.bash" >&2
		exit 1
	fi

	mkdir -p "${DATA_DIR}"
}

fct_wait_for_topic() {
	local topic="$1"
	local timeout="${2:-30}"
	local elapsed=0

	echo "[INFO] Waiting for topic ${topic} ..."
	while [[ ${elapsed} -lt ${timeout} ]]; do
		if rostopic list 2>/dev/null | grep -q "${topic}"; then
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	echo "[ERROR] Timeout waiting for topic: ${topic}" >&2
	return 1
}

fct_run_calibration() {
	source /opt/ros/noetic/setup.bash
	source "${WS_DIR}/devel/setup.bash"

	echo "========================================"
	echo " LiDAR-IMU Calibration"
	echo "========================================"
	echo " Bag:   ${BAG_FILE}"
	echo " Launch: ${LAUNCH}"
	if [[ -n "${PLAY_RATE}" ]]; then
		echo " Rate:  ${PLAY_RATE}x"
	fi
	echo "========================================"

	roscore &
	local roscore_pid=$!
	sleep 3

	if ! kill -0 "${roscore_pid}" 2>/dev/null; then
		echo "[ERROR] roscore failed to start" >&2
		exit 1
	fi

	roslaunch lidar_imu_init "${LAUNCH}" rviz:=false &
	local node_pid=$!
	sleep 5

	if ! kill -0 "${node_pid}" 2>/dev/null; then
		echo "[ERROR] li_init node failed to start" >&2
		kill "${roscore_pid}" 2>/dev/null || true
		exit 1
	fi

	local play_args=()
	if [[ -n "${PLAY_RATE}" ]]; then
		play_args+=("--rate" "${PLAY_RATE}")
	fi
	play_args+=("${BAG_FILE}")

	echo "[INFO] Playing rosbag ..."
	rosbag play "${play_args[@]}"
	local bag_exit=$?

	echo "[INFO] Rosbag finished (exit=${bag_exit}), waiting for refinement ..."
	echo "[INFO] li_init will continue online refinement after bag playback."

	local wait_time=0
	local max_wait=$(( $(rosbag info --yaml "${BAG_FILE}" 2>/dev/null \
		| grep -oP 'duration: \K[0-9.]+' || echo "60") + 60 ))

	while kill -0 "${node_pid}" 2>/dev/null && [[ ${wait_time} -lt ${max_wait} ]]; do
		sleep 2
		wait_time=$((wait_time + 2))
	done

	if kill -0 "${node_pid}" 2>/dev/null; then
		echo "[WARN] Node still running after ${max_wait}s, sending SIGINT"
		kill -INT "${node_pid}" 2>/dev/null || true
		sleep 5
		kill "${node_pid}" 2>/dev/null || true
	fi

	kill "${roscore_pid}" 2>/dev/null || true
	wait "${roscore_pid}" 2>/dev/null || true
}

fct_collect_result() {
	if [[ -f "${RESULT_SRC}" ]]; then
		cp "${RESULT_SRC}" "${RESULT_DST}"
		echo ""
		echo "========================================"
		echo " Calibration Result"
		echo "========================================"
		cat "${RESULT_DST}"
		echo ""
		echo "Result saved to: ${RESULT_DST}"
		echo "========================================"
	else
		echo "[WARN] Result file not found: ${RESULT_SRC}" >&2
		echo "[WARN] Calibration may not have completed." >&2
	fi
}

fct_cleanup() {
	set +e
	pkill -f "roscore" 2>/dev/null || true
	pkill -f "li_init" 2>/dev/null || true
	pkill -f "rosmaster" 2>/dev/null || true
}

main() {
	set -euo pipefail
	trap fct_cleanup EXIT

	fct_parse_arguments "$@"
	fct_validate_inputs
	fct_run_calibration
	fct_collect_result
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
