# LiDAR Debug

Diagnose Livox MID360 / Mid360s from NIC to driver output.
Covers network reachability and driver JSON config (SLAM diagnosis is in `lio-bringup`).

## Step 0: Identify Model

| Model | `model` variable | Vendor config |
|-------|-----------------|---------------|
| MID360 | `mid360` | `linker/livox_ros_driver2/config/MID360_config.json` |
| Mid360s | `mid360s` | `linker/livox_ros_driver2/config/MID360s_config.json` |

File naming: `mid360.*` for MID360, `mid360s.*` for Mid360s. Never cross-use.

## Layer 1 — Network

### 1.1 Check interfaces

```bash
ssh nv@192.168.55.1 "ip addr show"
```

| Interface | Purpose | Typical subnet |
|-----------|---------|----------------|
| `eth0` | Hardwired LiDAR | `192.168.2.0/24` |
| `wlan0` | WiFi / DDS bridge | `192.168.110.0/22` |
| `l4tbr0` | USB → host | `192.168.55.0/24` |

### 1.2 Read configured IP from JSON

```bash
ssh nv@192.168.55.1 "cat /home/nv/realworld_modules/run_scripts/config/${model}.json"
```

Extract: `host_net_info` (Object for MID360, Array for Mid360s) and `lidar_configs[0].ip`.

### 1.3 Match subnet

Compare config IPs vs actual interface IPs. If mismatched:

```bash
ssh nv@192.168.55.1 "sudo ip addr add <host_ip>/24 dev eth0"
```

Persist via NetworkManager:

```bash
ssh nv@192.168.55.1 "sudo nmcli connection modify Livox-LiDAR ipv4.method manual ipv4.addresses '<primary_ip>/24,<secondary_ip>/24' && sudo nmcli connection down Livox-LiDAR && sudo nmcli connection up Livox-LiDAR"
```

### 1.4 Verify reachability

```bash
ssh nv@192.168.55.1 "ping -c 3 <lidar_ip>"
```

### 1.5 Check ARP

```bash
ssh nv@192.168.55.1 "ip neigh show | grep <lidar_ip>"
```

### 1.6 Common: bind failed (detection socket)

**Error:** `Create detection socket failed`, `bind failed`

**Cause:** JSON host IP not assigned to any interface, or port 56000 in use.

**Fix:**

```bash
# Check host IP in JSON
ssh nv@192.168.55.1 "grep -E 'cmd_data_ip|host_ip' /home/nv/realworld_modules/run_scripts/config/${model}.json"
# Assign it
ssh nv@192.168.55.1 "sudo ip addr add <host_ip>/24 dev eth0"
# Clear stale process
ssh nv@192.168.55.1 "sudo kill \$(ss -ulpn | grep 56000 | grep -oP 'pid=\K[0-9]+') 2>/dev/null || true"
```

### 1.7 Common: detection OK but firmware query fails (-4)

**Error:** `Query livox lidar Fw type failed, the status:-4`

**Cause:** LiDAR IP reset to a different subnet than JSON config.

**Fix:**

```bash
# Capture real LiDAR IP
ssh nv@192.168.55.1 "sudo tcpdump -i eth0 -nn -c 5 udp port 56000 -X"
# Update JSON with real IP, sync, restart
```

## Layer 2 — Driver Config

### 2.1 Config location

`run_scripts/config/{model}.json` referenced by Livox driver launch.

### 2.2 JSON structure

**MID360:** key `"MID360"`, `host_net_info` is an Object. Each port has its own IP field.

**Mid360s:** key `"Mid360s"`, `host_net_info` is an Array. Single `host_ip` per entry.

Always use the vendor template from `linker/livox_ros_driver2/config/`.

### 2.3 Common: Params check failed

**Error:** `Params check failed, all livox lidars config is empty.`

**Causes (in order):**
1. Device-keyed section name wrong (MID360 vs Mid360s)
2. `host_net_info` structure mismatch (Object vs Array)
3. LiDAR not reachable (Layer 1)

### 2.4 Launch param: xfer_format

| Value | Output | Consumer |
|-------|--------|----------|
| `0` | `sensor_msgs::PointCloud2` | FAST-LIO2, RViz |
| `1` | `livox_ros_driver2::CustomMsg` | Custom nodes |

Set `xfer_format=0` for FAST-LIO2.

## Docker context

LiDAR driver runs inside `vtol/lio-jetson` container:

```bash
# Check driver output inside container
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'source /opt/ros/humble/setup.bash && ros2 topic list | grep livox'"
```

Expected: `/livox/lidar`, `/livox/imu`.

## Debugging Checklist

```
1. ip addr show                        ← verify NIC IPs
2. cat {model}.json                    ← read host/lidar IPs
3. subnet match?                       ← if no: ip addr add <host_ip>/24 dev eth0
4. ping <lidar_ip>                     ← if no: cable/ARP
5. tcpdump -i eth0 udp port 56000      ← capture real LiDAR IP (if FW query -4)
6. docker exec vtol-lio ros2 topic list ← driver publishing?
```

## Key Files

| File | Role |
|------|------|
| `run_scripts/config/{model}.json` | Driver JSON config |
| `run_scripts/config/livox_mid360.json` | LiDAR network config template |
| `linker/livox_ros_driver2/config/` | Vendor reference configs |
