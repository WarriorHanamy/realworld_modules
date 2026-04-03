#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
BAG_NAME="all_exclude_camera_$(date +%Y%m%d_%H%M%S).bag"
ALL_TOPICS=$(rostopic list 2>/dev/null)
FILTERED_TOPICS=$(echo "$ALL_TOPICS" | grep -v '^/camera')
if [ -z "$FILTERED_TOPICS" ]; then
  echo "No topics found to record."
  exit 1
fi
TOPIC_ARRAY=()
while IFS= read -r topic; do
  [ -n "$topic" ] && TOPIC_ARRAY+=("$topic")
done <<< "$FILTERED_TOPICS"
echo "Recording all topics except /camera/*"
echo "Output: $BAG_NAME"
rosbag record --tcpnodelay -O "$BAG_NAME" "${TOPIC_ARRAY[@]}"
