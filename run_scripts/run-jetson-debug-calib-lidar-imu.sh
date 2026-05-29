#!/usr/bin/env bash
#
# LiDAR-IMU Calibration Runner (live mode default)
# Starts livox_ros_driver2 + lidar_imu_init via integrated launch.
# Falls back to rosbag playback when --bag is specified.
# ==============================================================================
readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

readonly DATA_DIR="/data"
readonly WS_DIR="/root/catkin_ws"
readonly RESULT_SRC="${WS_DIR}/src/LiDAR_IMU_Init/result/Initialization_result.txt"
readonly RESULT_DST="${DATA_DIR}/Initialization_result.txt"
readonly DEFAULT_LAUNCH="livox_mid360_integrated.launch"
readonly DEFAULT_TIMEOUT=300

BAG_FILE=""
LAUNCH="${DEFAULT_LAUNCH}"
PLAY_RATE=""
TIMEOUT="${DEFAULT_TIMEOUT}"
IMU_BRIDGE=true

fct_usage() {
	cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Live mode (default):
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --timeout 600

Rosbag mode:
  ${SCRIPT_NAME} --bag calibration_data.bag
  ${SCRIPT_NAME} --bag calibration_data.bag --rate 0.5

Options:
  -h, --help          Show this help and exit
  -l, --launch NAME   ROS launch file (default: ${DEFAULT_LAUNCH})
  -b, --bag FILE      Play rosbag instead of live sensor
  -r, --rate RATE     Rosbag play rate (only with --bag)
  -t, --timeout SECS  Max wait for result in live mode (default: ${DEFAULT_TIMEOUT})
  --no-imu-bridge     Skip IMU bridge receiver node
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
			LAUNCH="$2"
			shift 2
			;;
		-b | --bag)
			BAG_FILE="$2"
			shift 2
			;;
		-r | --rate)
			PLAY_RATE="$2"
			shift 2
			;;
		-t | --timeout)
			TIMEOUT="$2"
			shift 2
			;;
		--no-imu-bridge)
			IMU_BRIDGE=false
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			echo "Unknown option: $1" >&2
			fct_usage >&2
			exit 2
			;;
		*)
			echo "Unexpected argument: $1" >&2
			fct_usage >&2
			exit 2
			;;
		esac
	done
}

fct_validate_inputs() {
	if [[ -n "${BAG_FILE}" && ! -f "${BAG_FILE}" ]]; then
		echo "Error: bag file not found: ${BAG_FILE}" >&2
		exit 1
	fi

	if [[ ! -f "${WS_DIR}/devel/setup.bash" ]]; then
		echo "Error: catkin workspace not built: ${WS_DIR}/devel/setup.bash" >&2
		exit 1
	fi

	mkdir -p "${DATA_DIR}"
}

fct_start_roscore() {
	roscore &
	local pid=$!
	sleep 3

	if ! kill -0 "${pid}" 2>/dev/null; then
		echo "[ERROR] roscore failed to start" >&2
		exit 1
	fi
	echo "${pid}"
}

fct_run_live() {
	source /opt/ros/noetic/setup.bash
	source "${WS_DIR}/devel/setup.bash"

	echo "========================================"
	echo " LiDAR-IMU Calibration (live mode)"
	echo " Launch: ${LAUNCH}"
	echo " Timeout: ${TIMEOUT}s"
	echo "========================================"

	local roscore_pid
	roscore_pid=$(fct_start_roscore)

	# Start integrated launch (livox_ros_driver2 + lidar_imu_init)
	roslaunch lidar_imu_init "${LAUNCH}" use_rviz:=false &
	local launch_pid=$!
	sleep 5

	if ! kill -0 "${launch_pid}" 2>/dev/null; then
		echo "[ERROR] Integrated launch failed: ${LAUNCH}" >&2
		kill "${roscore_pid}" 2>/dev/null || true
		exit 1
	fi

	# Start IMU bridge receiver
	local imu_pid=""
	if [[ "${IMU_BRIDGE}" == true ]]; then
		rosrun imu_bridge_ros1 imu_receiver_node \
			_socket_path:=/tmp/imu_bridge.sock \
			_publish_topic:=/mavros/imu/data_raw &
		imu_pid=$!
		echo "[INFO] IMU bridge started (pid=${imu_pid})"
	fi

	echo "[INFO] Calibration running, waiting for result ..."
	echo "[INFO] Press Ctrl-C to stop."

	# Monitor result file
	local elapsed=0
	while [[ ${elapsed} -lt ${TIMEOUT} ]]; do
		if [[ -f "${RESULT_SRC}" ]]; then
			echo "[INFO] Result file detected after ${elapsed}s"
			sleep 2
			break
		fi

		if ! kill -0 "${launch_pid}" 2>/dev/null; then
			echo "[WARN] Launch process exited unexpectedly" >&2
			break
		fi

		sleep 2
		elapsed=$((elapsed + 2))
	done

	if [[ ${elapsed} -ge ${TIMEOUT} ]]; then
		echo "[WARN] Timeout after ${TIMEOUT}s, no result file found" >&2
	fi

	# Cleanup
	[[ -n "${imu_pid}" ]] && kill "${imu_pid}" 2>/dev/null || true
	kill "${launch_pid}" 2>/dev/null || true
	sleep 2
	kill "${launch_pid}" 2>/dev/null || true
	kill "${roscore_pid}" 2>/dev/null || true
	wait "${roscore_pid}" 2>/dev/null || true
}

fct_run_bag() {
	source /opt/ros/noetic/setup.bash
	source "${WS_DIR}/devel/setup.bash"

	echo "========================================"
	echo " LiDAR-IMU Calibration (rosbag mode)"
	echo " Bag:   ${BAG_FILE}"
	echo " Launch: ${LAUNCH}"
	if [[ -n "${PLAY_RATE}" ]]; then
		echo " Rate:  ${PLAY_RATE}x"
	fi
	echo "========================================"

	local roscore_pid
	roscore_pid=$(fct_start_roscore)

	# Use non-integrated launch for bag mode (no need for livox_ros_driver2)
	local bag_launch="${LAUNCH}"
	if [[ "${LAUNCH}" == "livox_mid360_integrated.launch" ]]; then
		bag_launch="calib_with_imu.launch"
		echo "[INFO] Switching to ${bag_launch} for rosbag playback"
	fi

	roslaunch lidar_imu_init "${bag_launch}" rviz:=false &
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
	pkill -f "imu_receiver_node" 2>/dev/null || true
	pkill -f "livox_lidar_publisher2" 2>/dev/null || true
}

main() {
	set -euo pipefail
	trap fct_cleanup EXIT

	fct_parse_arguments "$@"
	fct_validate_inputs

	if [[ -n "${BAG_FILE}" ]]; then
		fct_run_bag
	else
		fct_run_live
	fi

	fct_collect_result
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
