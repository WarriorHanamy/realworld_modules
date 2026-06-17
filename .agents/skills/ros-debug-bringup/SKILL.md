# ros-debug-bringup

Common pitfalls when writing ROS2 bringup scripts and how to verify independently.

## 1. Launch File XML Pitfalls

### Comments must not contain `--`

The XML comment token `<!--`...`-->` forbids `--` anywhere inside:

```xml
<!-- OK -->
<!-- Invalid -- because of double dash -->
```

Fix: replace `--` with single `-` or rephrase.

**Verification:**

```bash
python3 -c "
import xml.etree.ElementTree as ET
try:
    ET.parse('path/to/file.launch.xml')
    print('XML well-formed')
except ET.ParseError as e:
    print(f'XML ERROR: {e}')
"
```

### Angle brackets in comments

Avoid `<` and `>` in XML comments:

```xml
<!-- NOK: has angle brackets <here> -->
<!-- OK: rephrase without angle brackets -->
```

## 2. Independent Node Verification

Before plugging into the full bringup, verify a ROS2 node in isolation:

```bash
# 1. Start the container (single service)
docker start vtol-lio

# 2. Check node is alive
docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && ros2 node list'

# 3. Check topics are registered
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && ros2 topic list'"

# 4. Check topic data rate
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && timeout 3 ros2 topic hz /livox/lidar'"

# 5. Check message content
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && timeout 2 ros2 topic echo /livox/lidar --once'"

# 6. Check no error in log
ssh nv@192.168.55.1 "docker logs vtol-lio --tail 20 | grep -i error || echo 'No errors'"
```

### Headless tmux verification

```bash
tmux new-session -d -s test-session -n test bash
tmux send-keys -t test-session:test 'docker start vtol-lio' C-m
sleep 5
output=$(tmux capture-pane -t test-session:test -p -S -20)
echo "$output" | grep -q 'error' && echo "FAIL" || echo "PASS"
tmux kill-session -t test-session
```

## 3. Python Lazy Import (debug mode)

When a ROS2 node has a debug mode that skips heavy dependencies (onnxruntime,
torch, tensorrt), import them lazily:

```python
class MyNode:
    def __init__(self):
        debug_mode = self.declare_parameter('debug_mode', False).value
        if not debug_mode:
            from onnxruntime import InferenceSession  # lazy
```

## 4. Docker Container Startup Coordination

ROS2 uses DDS discovery (not a central roscore). Containers discover each
other via FastDDS. No explicit master is needed, but startup order affects
topic availability:

```bash
# Start in order: px4-connector first (provides IMU), then LIO (consumes IMU)
docker start vtol-px4-connector
sleep 3
docker start vtol-lio
sleep 5
docker start vtol-bht
```

## 5. Remote ROS2 Visualization

For visualizing on the host machine:

```bash
# On host, start debug container
uv run viz lio

# Inside container, ROS2 nodes discover Jetson topics via FastDDS debug profile
docker exec -it vtol-fastlio-debug-host \
  bash -c 'source /opt/ros/humble/setup.bash && rviz2'
```

## 6. Delivery Checklist

- [ ] Launch file XML validated (`python3 -c "import xml.etree.ElementTree; ET.parse('file.launch.xml')"`)
- [ ] No `--` inside XML comments
- [ ] Python nodes use lazy imports for heavy deps in debug mode
- [ ] Independent verification: node starts, topic registered, topic has data
- [ ] If multi-pane tmux: staggered container starts for DDS discovery
- [ ] If multi-machine: both sides use `fastdds-debug.xml` profile
