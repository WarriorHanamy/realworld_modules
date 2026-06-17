---
name: lidar-debug
description: Diagnose and fix LiDAR bringup failures for Livox MID360 or Mid360s — network reachability, driver JSON config, faster_lio message type alignment. Use when user reports LiDAR not working, params check failed, SLAM not receiving data, or network/ARP issues on the `{DEVICE}` Jetson.
---

# LiDAR Debug

Debug a LiDAR deployment from NIC to SLAM. Supports both **MID360** and
**Mid360s** models. The workflow covers three layers: **network** (find the
LiDAR IP, fix subnet mismatch), **driver config** (Livox JSON structure, param
naming), and **SLAM config** (faster_lio message type alignment).

---

## Step 0: Identify Model

Ask the user which Livox LiDAR model they are using. Set `model` for all
subsequent steps.

| Model    | `model` variable | Vendor config template                       |
| -------- | ---------------- | -------------------------------------------- |
| MID360   | `mid360`          | `src/linker/livox_ros_driver2/config/MID360_config.json` |
| Mid360s  | `mid360s`         | `src/linker/livox_ros_driver2/config/MID360s_config.json` |

**File naming rule**: bringup files MUST match the hardware — `mid360.*` for
MID360, `mid360s.*` for Mid360s. Never cross-use.

| Hardware  | JSON config    | SLAM YAML      | Driver launch            | Mapping launch              |
| --------- | -------------- | -------------- | ------------------------ | --------------------------- |
| MID360s   | `mid360s.json`  | `mid360s.yaml`  | `msg_mid360s.launch`       | `mapping_mid360.launch`      |

If the existing files don't match the model, rename them. Copy the vendor
config as the basis for the JSON; adjust YAML and launch paths accordingly.

---

## Layer 1 — Network: From NIC to LiDAR

### 1.1 Check Jetson network interfaces

```bash
ssh nv@192.168.55.1 "ip addr show"
```

Look for:

| Interface | Purpose                          | Typical subnet     |
| --------- | -------------------------------- | ------------------ |
| `eth0`    | Hardwired Ethernet → LiDAR        | `192.168.x.0/24`   |
| `wlan0`   | WiFi → internet / ROS bridge      | `192.168.110.0/22` |
| `l4tbr0`  | USB bridge → host PC              | `192.168.55.0/24`  |

### 1.2 Read the configured IP from JSON

```bash
cat /home/nv/ros1-yopo/src/bringup/config/{model}.json
```

Extract these two fields:

- For Mid360s (`"host_net_info"` is an Array): `host_net_info[0]` → `"host_ip"`
- For MID360 (`"host_net_info"` is an Object): `host_net_info` → `"cmd_data_ip"`
- `lidar_configs[0]` → `"ip"` (lidar side, e.g. `"192.168.2.88"`)

### 1.3 Match subnet

Compare the config IPs against the actual interface IPs (`ip addr show`).

If the LiDAR subnet does not exist on any Jetson interface (e.g. config says
`192.168.2.x` but eth0 is on `192.168.1.x`), add a secondary IP to the
physical port the LiDAR is connected to:

```bash
ssh nv@192.168.55.1 "sudo ip addr add <host_ip>/24 dev eth0"
# Example: sudo ip addr add 192.168.2.50/24 dev eth0
```

**Persistence via NetworkManager**: This change is lost on reboot. To make it
permanent, modify the ethernet NM connection to hold both IPs:

```bash
ssh nv@192.168.55.1 "sudo nmcli connection modify Livox-LiDAR \
  ipv4.method manual \
  ipv4.addresses '<primary_ip>/24,<secondary_ip>/24'"
ssh nv@192.168.55.1 "sudo nmcli connection down Livox-LiDAR; \
  sudo nmcli connection up Livox-LiDAR"
# Example: 192.168.2.50 as primary, 192.168.1.50 as secondary for LiDAR on 1.x subnet
ssh nv@192.168.55.1 "sudo nmcli connection modify Livox-LiDAR \
  ipv4.method manual \
  ipv4.addresses '192.168.2.50/24,192.168.1.50/24'"
```

Verify both IPs survive `nmcli connection up`:

```bash
ssh nv@192.168.55.1 "ip addr show eth0 | grep 'inet '"
# Expected:
#     inet 192.168.2.50/24 ...
#     inet 192.168.1.50/24 ...
```

### 1.4 Verify reachability

```bash
ssh nv@192.168.55.1 "ping -c 3 <lidar_ip>"
# Example: ping -c 3 192.168.2.88
```

### 1.5 Check ARP table

```bash
ssh nv@192.168.55.1 "ip neigh show | grep <lidar_ip>"
```

A successful ping populates the ARP table with the LiDAR MAC address.

### 1.6 Common error: bind failed (detection socket)

**Error signature:**
```
bind failed
[error] Create detection socket failed.
[error] Create detection channel failed.
Failed to init livox lidar sdk.
```

**Root cause**: Livox SDK internally extracts the host IP from `host_net_info`
in the JSON (`cmd_data_ip` for MID360 object, `host_ip[0].host_ip` for Mid360s
array) and calls `bind()` on UDP port **56000** (`kDetectionPort`). If that IP
does not belong to any local network interface, `bind()` returns `EADDRNOTAVAIL`.

**Diagnosis** — read configured host IP, check interfaces, check port:
```bash
ssh nv@192.168.55.1 "cat src/bringup/config/{model}.json | grep -E 'cmd_data_ip|host_ip'"
ssh nv@192.168.55.1 "ip addr show | grep <host_ip>"
ssh nv@192.168.55.1 "ss -ulpn | grep 56000"
```

**Fix — choose the right path:**

| Scenario | Action |
| -------- | ------ |
| JSON host IP correct but not assigned to any interface | `sudo ip addr add <host_ip>/24 dev eth0` (see 1.3) |
| JSON host IP does not match the Jetson's LiDAR-facing subnet | ① edit JSON: set `cmd_data_ip` (MID360) or `host_ip[0].host_ip` (Mid360s) to a valid IP on the same subnet as the LiDAR; ② add that IP to eth0 |
| Port 56000 already in use (e.g. stale driver process) | `sudo kill <pid>` or restart the node |

### 1.7 Common error: Detection succeeds but firmware query fails (status -4)

**Error signature:**

The driver repeatedly logs:

```
[info] Handle detection data, handle:<N>, dev_type:9, sn:<SN>, cmd_port:56100
[error] Query livox lidar Fw type failed, the status:-4
```

This pattern repeats every second — detection works but every firmware query
fails.

**Root cause**: The LiDAR's IP was reset to a different subnet than the one
configured in the JSON config (`lidar_configs[0].ip`). UDP broadcast detection
(port 56000, `255.255.255.255`) traverses all subnets and succeeds, but the
subsequent unicast command/firmware-queries use the JSON-configured IP, which
no longer matches the LiDAR's actual address.

**Diagnosis** — four-step chain:

`①` Confirm the driver sockets are bound correctly (detection is working):

```bash
ssh nv@192.168.55.1 "ss -ulpn | grep -E '56000|56101'"
```

`②` Try ping + ARP to the configured LiDAR IP — this will likely fail,
confirming the IP mismatch:

```bash
ssh nv@192.168.55.1 "ping -c 3 -W2 <lidar_ip>"
ssh nv@192.168.55.1 "ip neigh show | grep <lidar_ip>"
# Typical: FAILED (no ARP response)
```

`③` Install tcpdump on the device and capture the LiDAR's detection broadcast
response to discover its actual IP:

```bash
ssh nv@192.168.55.1 "sudo apt-get install -y tcpdump"
ssh nv@192.168.55.1 "sudo tcpdump -i eth0 -nn -c 5 udp port 56000 -X"
```

The LiDAR responds with a UDP packet originating from its real IP. Read the
source IP from the tcpdump header line:

```
IP <lidar_actual_ip>.56000 > 255.255.255.255.56000
```

`④` (Optional) Verify the response matches your LiDAR by decoding the SN from
the hex dump — look for ASCII in the payload:

```
0x0030:  ... 3437 4d44 4e37 4230 3033 3030 3338  ...
               47  M   D   N   7   B   0   0   3   0   0   3   8
```

**Fix** — update JSON config and persist the new subnet:

`①` Update `{model}.json` on the devel machine:
- Change `lidar_configs[0].ip` to the LiDAR's actual IP found in step `③`
- Change all `host_net_info` IP fields to an address on the **same subnet** as
  the LiDAR (add a secondary IP to eth0 as needed)

```bash
# Example: LiDAR is at 192.168.1.138, host was configured for 192.168.2.x
# Edit {model}.json:
#   "ip": "192.168.1.138"                         (was 192.168.2.88)
#   "cmd_data_ip": "192.168.1.50", "push_msg_ip": "192.168.1.50", ...  (was 192.168.2.50)
```

`②` Sync the updated config and add the host secondary IP:

```bash
rsync -avz src/bringup/config/{model}.json \
  nv@192.168.55.1:/home/nv/ros1-yopo/src/bringup/config/{model}.json
ssh nv@192.168.55.1 "sudo ip addr add <host_secondary_ip>/24 dev eth0"
# Persist via NetworkManager (see 1.3)
```

`③` Kill any stale driver process and restart:

```bash
ssh nv@192.168.55.1 "source /opt/ros/noetic/setup.bash \
  && source /home/nv/ros1-yopo/deploy-side/devel/setup.bash \
  && pkill -9 -f livox_ros_driver; pkill -9 -f roslaunch; \
  sleep 2 && roslaunch bringup msg_{model}.launch xfer_format:=0"
```

**Verification**: The log should now show:

```
[info] Query Fw type succ, the fw_type:1
[info] Update lidar:<N> succ.
successfully set data type ...
successfully change work mode ...
[ INFO] livox/imu publish imu data
[ INFO] livox/lidar publish use PointCloud2 format
```

---

## Layer 2 — Driver Config: Livox JSON Config

### 2.1 Config file location

`src/bringup/config/{model}.json` — referenced by the launch file via:

```xml
<param name="user_config_path" type="string"
       value="$(find bringup)/config/{model}.json"/>
```

### 2.2 JSON structure by model

**MID360** — key `"MID360"`, `host_net_info` is an Object:

```json
{
  "lidar_summary_info" : {
    "lidar_type": 8
  },
  "MID360": {
    "lidar_net_info" : {
      "cmd_data_port": 56100,
      "push_msg_port": 56200,
      "point_data_port": 56300,
      "imu_data_port": 56400,
      "log_data_port": 56500
    },
    "host_net_info" : {
      "cmd_data_ip" : "192.168.2.50",
      "cmd_data_port": 56101,
      "push_msg_ip": "192.168.2.50",
      "push_msg_port": 56201,
      "point_data_ip": "192.168.2.50",
      "point_data_port": 56301,
      "imu_data_ip" : "192.168.2.50",
      "imu_data_port": 56401,
      "log_data_ip" : "",
      "log_data_port": 56501
    }
  },
  "lidar_configs" : [
    {
      "ip" : "192.168.2.88",
      "pcl_data_type" : 1,
      "pattern_mode" : 0,
      "extrinsic_parameter" : { "roll": 0, "pitch": 0, ... }
    }
  ]
}
```

**Mid360s** — key `"Mid360s"`, `host_net_info` is an Array:

```json
{
  "lidar_summary_info" : {
    "lidar_type": 8
  },
  "Mid360s": {
    "lidar_net_info" : {
      "cmd_data_port"  : 56100,
      "push_msg_port"  : 56200,
      "point_data_port": 56300,
      "imu_data_port"  : 56400,
      "log_data_port"  : 56500
    },
    "host_net_info" : [
      {
        "host_ip"        : "192.168.2.50",
        "cmd_data_port"  : 56101,
        "push_msg_port"  : 56201,
        "point_data_port": 56301,
        "imu_data_port"  : 56401,
        "log_data_port"  : 56501
      }
    ]
  },
  "lidar_configs" : [
    {
      "ip" : "192.168.2.88",
      "pcl_data_type" : 1,
      "pattern_mode" : 0,
      "extrinsic_parameter" : { "roll": 0, "pitch": 0, ... }
    }
  ]
}
```

**Always use the vendor config from `src/linker/livox_ros_driver2/config/`
as the template — do NOT write from scratch or copy across device types.**

### 2.3 Critical differences: MID360 vs Mid360s

| Aspect                | MID360 (`config/MID360_config.json`)          | Mid360s (`config/MID360s_config.json`)         |
| --------------------- | --------------------------------------------- | ---------------------------------------------- |
| Key name              | `"MID360"` (uppercase)                        | `"Mid360s"` (mixed case, with `s`)             |
| `host_net_info`       | **Object** (each port has its own IP field)   | **Array** (single `host_ip` per entry)         |
| `lidar_summary_info.lidar_type` | `8` (both use 8; SDK C++ enum `kLivoxLidarTypeMid360 = 9`) | `8` (SDK C++ enum `kLivoxLidarTypeMid360s = 35`) |
| Port formatting       | no spaces before colon: `"cmd_data_port":`    | spaces before colon: `"cmd_data_port"  :`       |

### 2.4 Common error: Params check failed

**Error:**
```
[error] Params check failed, all livox lidars config is empty.
Failed to init livox lidar sdk.
```

**Likely causes (in order):**

1. The device-keyed section name does not match the hardware. Use the correct
   vendor template (`MID360_config.json` or `MID360s_config.json`). The section
   key and `host_net_info` format must both be consistent with the hardware.
2. `host_net_info` structure mismatches SDK expectation (Object vs Array).
3. The LiDAR is not reachable on the network (see Layer 1).
4. `lidar_summary_info` or `lidar_configs` section is missing.

> **Note**: `bind failed` / `Create detection socket failed` in the log usually
> points to **network-layer** issue (host IP not assigned, see 1.6), not JSON
> structure. If the JSON is structurally valid but the driver still fails with
> `bind failed`, diagnose per 1.6.

### 2.5 Launch param: xfer_format

```xml
<arg name="xfer_format" default="0"/>
```

| Value | Driver output type                        | Consumer       |
| ----- | ----------------------------------------- | -------------- |
| `0`   | `sensor_msgs::PointCloud2`                | faster_lio, rviz |
| `1`   | `livox_ros_driver2::CustomMsg` (default)  | Custom nodes   |

**Always set `xfer_format=0` when the downstream SLAM is faster_lio
(`lidar_type: 6`).**

---

## Layer 3 — SLAM Config: faster_lio

### 3.1 Config location

`src/bringup/config/{model}.yaml` — loaded by `mapping_{model}.launch`:

```xml
<rosparam command="load" file="$(find bringup)/config/{model}.yaml" />
```

### 3.2 lidar_type

```yaml
preprocess:
    lidar_type: 6   # <-- critical
```

| Value | Message type                         | Driver xfer_format |
| ----- | ------------------------------------ | ------------------ |
| `1`   | `livox_ros_driver::CustomMsg` (old)  | `1` (custom msg)   |
| `6`   | `sensor_msgs::PointCloud2`           | `0` (PointCloud2)  |

Rule: **`lidar_type` must match `xfer_format`**, or the mapping node
subscribes to the wrong message type and silently receives zero points.

### 3.3 Common error: No point, mapping finishes immediately

**Error:**
```
Using AVIA Lidar (livox_ros_driver::CustomMsg)
No point, skip this scan!
finishing mapping
```

**Cause**: `lidar_type=1` but the driver publishes `sensor_msgs::PointCloud2`
(`xfer_format=0`), or vice versa. The subscriber never receives messages.

**Fix**: Set `lidar_type=6` and `xfer_format=0` together.

### 3.4 Other faster_lio topics

```yaml
common:
    lid_topic: "/livox/lidar"   # must match driver output topic
    imu_topic: "/livox/imu"     # must match driver output topic
```

Confirm topics match by inspecting the driver launch file
(`msg_{model}.launch`) — no explicit topic remaps; default topic path is
`/livox/lidar` and `/livox/imu`.

---

## Debugging Checklist

Use this 7-step flow when bringup fails (substitute `{model}`):

```
1. ip addr show                        ← verify NIC IPs
2. cat {model}.json                    ← read host/lidar IPs
3. subnet match?                       ← if no: ip addr add <host_ip>/24 dev eth0
4. port 56000 conflict?                ← if yes: ss -ulpn | grep 56000 → kill stale process
5. ping <lidar_ip>                     ← if no: ARP/cable issue
5.5. tcpdump -i eth0 udp port 56000  ← if detection OK but FW query fails: capture real LiDAR IP (see 1.7)
6. catkin build livox_ros_driver2     ← if build failed: package.xml missing?
7. roslaunch msg_{model}.launch        ← check "Params check failed"
8. roslaunch mapping_{model}.launch    ← check "lidar_type 6"
```

---

### Error Decoder

| Symptom                                                       | Root cause                      | Fix                                                    |
| ------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------ |
| `ROS_DISTRO: unbound variable`                                | ROS env not exported before source | Add to `env.sh`                                        |
| `cannot launch node of type [...] livox_ros_driver2`         | catkin skipped the package      | Generate `package.xml`, rebuild                        |
| `kLivoxLidarTypeMid360s is not a member`                     | SDK too old for this driver     | Add missing enum to `/usr/local/include/livox_lidar_def.h` |
| `Params check failed, all livox lidars config is empty`      | JSON key/structure mismatch     | Use correct vendor config (`MID360_config.json` / `MID360s_config.json`) |
| `Destination Host Unreachable` for LiDAR IP                  | Subnet mismatch                 | `ip addr add <host_ip>/24 dev eth0` |
| `bind failed` + `Create detection socket failed`             | Host IP not assigned to any Jetson interface, or UDP 56000 already in use | ① `ip addr show` verify IP; ② `ss -ulpn \| grep 56000` check port; ③ `sudo ip addr add <host_ip>/24 dev eth0` (see 1.6) |
| Detection succeeds + `Query livox lidar Fw type failed, the status:-4` | LiDAR IP reset to a different subnet; JSON-configured IP stale | `tcpdump -i eth0 udp port 56000` to capture LiDAR's actual IP → update `{model}.json` + host subnet (see 1.7) |
| `Using AVIA Lidar (livox_ros_driver::CustomMsg)` → no points | Message type mismatch           | Set `xfer_format=0` + `lidar_type=6` |
| `Failed to open traj_file: ./Log/traj.txt`                   | Log directory missing           | `mkdir -p /home/nv/ros1-yopo/Log` |

---

## Key Files

| File                                              | Role                                           |
| ------------------------------------------------- | ---------------------------------------------- |
| `src/bringup/launch/msg_{model}.launch`             | Livox driver launch (`xfer_format` here)       |
| `src/bringup/launch/mapping_{model}.launch`         | faster_lio SLAM launch                         |
| `src/bringup/config/{model}.json`                   | Livox driver JSON config (NIC + device info)  |
| `src/bringup/config/{model}.yaml`                   | faster_lio mapping parameters (`lidar_type`)  |
| `tmux_scripts/infra_scripts/lidar_launch.sh`       | Combined bringup entry point                   |
| `tmux_scripts/infra_scripts/env.sh`                | Common ROS env pre-sourcing                    |
| `src/linker/livox_ros_driver2/config/MID360_config.json` | Vendor reference for MID360               |
| `src/linker/livox_ros_driver2/config/MID360s_config.json`| Vendor reference for Mid360s              |
| `/usr/local/include/livox_lidar_def.h`             | SDK device type enum (Jetson side)             |
