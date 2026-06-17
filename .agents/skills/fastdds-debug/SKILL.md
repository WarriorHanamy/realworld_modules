# fastdds-debug

Diagnose FastDDS discovery failures between Docker containers and across machines.
All containers use `rmw_fastrtps_cpp` with shared memory (SHM) + UDP transport.

## Profiles

The project has two FastDDS profiles:

| Profile | File | Use |
|---------|------|-----|
| `local` | `run_scripts/config/fastdds-local.xml` | Production: 127.0.0.1 only, UDP+SHM, ports 14910-14940 |
| `debug` | `run_scripts/config/fastdds-debug.xml` | Multi-interface: 127.0.0.1 + all known LAN IPs, ports 14900-14950 |

## Layer 1 — Domain ID

All containers must share `ROS_DOMAIN_ID=30`:

```bash
ssh nv@192.168.55.1 "docker inspect vtol-lio --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ROS_DOMAIN_ID"
ssh nv@192.168.55.1 "docker inspect vtol-px4-connector --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ROS_DOMAIN_ID"
```

Expected: `ROS_DOMAIN_ID=30` in both.

## Layer 2 — Participant Discovery

### 2.1 Are participants visible?

```bash
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c '
source /opt/ros/humble/setup.bash
ros2 daemon stop 2>/dev/null; sleep 1; ros2 daemon start 2>/dev/null
ros2 topic list 2>&1
'"
```

If only `/rosout` and `/parameter_events` appear, no DDS participants are
discovering each other.

### 2.2 Check network interfaces

Inside the container:

```bash
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c 'ip addr show | grep -E \"inet |lo:\"'"
```

FAST-LIO2 must see at least `lo` (127.0.0.1) and `eth0` (for intra-Jetson comms).

### 2.3 Check firewall

Host firewall may block UDP ports:

```bash
ssh nv@192.168.55.1 "sudo iptables -L -n | grep -E '1491[0-9]|1492[0-9]' || echo 'No FastDDS rules found (OK)'"
```

## Layer 3 — Inter-Machine Discovery (host ↔ Jetson)

### 3.1 Network connectivity

```bash
# From host
ping -c 2 192.168.55.1
```

### 3.2 Use debug profile

Host-side scripts mount `fastdds-debug.xml`:

```bash
# Check which profile is mounted
docker inspect vtol-fastlio-debug-host --format '{{range .Mounts}}{{.Source}}{{end}}' | grep -o 'fastdds-[a-z]*'
```

Expected: `fastdds-debug`.

### 3.3 Debug profile includes all interfaces

Verify the debug XML includes the host IP:

```bash
cat run_scripts/config/fastdds-debug.xml | grep -E 'metatrafficUnicastLocator|initialPeers'
```

Expected: entries for both `192.168.55.100` (host) and `192.168.55.1` (Jetson).

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ros2 topic list` shows only `/rosout` | Wrong ROS_DOMAIN_ID | Set `ROS_DOMAIN_ID=30` on ALL containers |
| Container A sees topics, B doesn't | Containers on different FastDDS profiles | Both must use same profile (local or debug) |
| Host can't see Jetson topics | Host uses `local` profile (127.0.0.1 only) | Switch host to `debug` profile |
| Intermittent discovery | UDP port conflict or firewall | Check `ss -ulpn \| grep 1491` for conflicts |
| SHM transport failure | SHM not configured or disabled | Check `docker run --ipc host` is set |
| `Participant not found` after network change | DDS discovery timeout | Wait 30s or restart containers |
| `rtps participant` with wrong IP | Hostname resolution issues | Use IP addresses in profile, not hostnames |

## Verification

### Single machine (Jetson)

```bash
ssh nv@192.168.55.1 "docker exec vtol-px4-connector bash -c '
source /opt/ros/humble/setup.bash
ros2 topic list 2>&1
'"
ssh nv@192.168.55.1 "docker exec vtol-lio bash -c '
source /opt/ros/humble/setup.bash
ros2 topic list 2>&1
'"
```

Both should see the same topics.

### Multi-machine (host)

```bash
# On host
docker exec vtol-fastlio-debug-host bash -c 'source /opt/ros/humble/setup.bash && ros2 topic list'
```

Should see PX4 topics and LIO topics from the Jetson.

## Key Files

| File | Role |
|------|------|
| `run_scripts/config/fastdds-local.xml` | Production profile (local only) |
| `run_scripts/config/fastdds-debug.xml` | Debug profile (multi-machine) |
| `run_scripts/config/uxrce-agent-local.refs` | Agent's FastDDS profile |
