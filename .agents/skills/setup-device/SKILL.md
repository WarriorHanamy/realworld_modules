---
name: setup-device
description: Use when setting up core essential utilities on a {DEVICE} Jetson device: initial SSH via IP, mDNS/avahi-daemon, tmux, NTP time sync via wlan0, bash default shell, oh-my-bash, WiFi lock to Diff* SSID, Livox SDK2, SSH key deployment. Triggers when user mentions initializing a fresh Jetson, mDNS not resolving, installing tmux/NTP/oh-my-bash, locking WiFi, or configuring a new device.
---

# Setup Device

Configure a {DEVICE} Jetson device with core utilities: initial SSH access via IP (fallback when
mDNS not available), mDNS/avahi-daemon so `nv-{DEVICE}.local` resolves, SSH key deployment for
passwordless access, WiFi lock to Diff* SSID (all other WiFi disabled), NTP time sync via
wlan0, tmux with mouse support, bash as default shell, oh-my-bash, default SSH working
directory, and Livox SDK2 installation.

## Prerequisites

- Jetson connected to devel machine via USB (RNDIS `192.168.55.1`) or on same WiFi network
- Jetson default credentials: user `nv`, password `nv`
- Internet access via wlan0 on the device (`ip addr show wlan0` shows `UP`)
- Target WiFi SSID matching `Diff*` exists in range (e.g. `DiffRobot（5G）`)
- Local machine has `sshpass`, `ssh-copy-id` installed
- If the NVIDIA BSP `rtl8822ce` driver fails 5 GHz WPA2 association (see Troubleshooting), run `resource/fix-rtw88-wifi.sh` first

## Get Device Name

Before starting, ask the user for the **device name** (e.g. `my-drone`, `drone42`, etc.).
Replace every `{DEVICE}` placeholder in this skill with the actual device name
before executing any command.

## Workflows

### 0. Establish initial SSH access via IP

On a fresh Jetson, mDNS (`nv-{DEVICE}.local`) is not yet configured. Connect via IP first.

**0.1 Try USB RNDIS link (192.168.55.1):**

```bash
sshpass -p 'nv' ssh -o StrictHostKeyChecking=accept-new nv@192.168.55.1 "echo SSH_OK"
```

USB RNDIS link is `192.168.55.1` — no WiFi or LAN required. This is the default link when
Jetson is connected to a devel machine via USB-C.

**0.2 Fallback: scan WiFi subnet for the Jetson:**

If USB link is not available and the device is on WiFi, scan the subnet the Diff* AP assigns
(typically `192.168.110.0/24`):

```bash
for ip in 192.168.110.{1..254}; do
  sshpass -p 'nv' ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=accept-new \
    nv@"$ip" "echo SSH_OK" 2>/dev/null && echo "FOUND at $ip" && break
done
```

**0.3 Verify basic connectivity:**

```bash
# Replace <IP> with the actual IP found above
ssh nv@<IP> "bash -lc 'hostname; whoami; sudo whoami'"
```

This confirms SSH works and passwordless sudo is available. If sudo prompts for a password,
configure NOPASSWD (see `ssh-target-setup` skill).

### 0.5. Configure mDNS (avahi-daemon)

mDNS lets the devel machine resolve `nv-{DEVICE}.local` without a DNS server.

**0.5.1 Install avahi-daemon on the device:**

```bash
ssh nv@<IP> "bash -lc 'sudo apt-get install -y avahi-daemon'"
```

**0.5.2 Set hostname to nv-{DEVICE} (if not already):**

```bash
ssh nv@<IP> "bash -lc '
CURRENT=\$(hostnamectl --static)
if [ \"\$CURRENT\" != \"nv-{DEVICE}\" ]; then
    sudo hostnamectl set-hostname nv-{DEVICE}
    sudo sed -i \"s/\$CURRENT/nv-{DEVICE}/g\" /etc/hosts
fi
'"
```

**0.5.3 Enable and start the daemon:**

```bash
ssh nv@<IP> "bash -lc 'sudo systemctl enable --now avahi-daemon'"
```

**0.5.4 Verify mDNS resolution from devel machine:**

```bash
avahi-resolve-host-name nv-{DEVICE}.local
```

This should return the device IP. If it fails, install `avahi-utils` on the devel machine:
`sudo apt-get install -y avahi-utils`.

If mDNS still fails, the devel machine's firewall may block UDP 5353. Check
`sudo systemctl status avahi-daemon` on both sides.

### 0.6. Deploy SSH keys for passwordless access

After mDNS is working, deploy SSH keys so all subsequent commands use key auth.

**0.6.1 Generate SSH key (if none exists):**

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)-$(date +%Y%m%d)"
```

**0.6.2 Deploy key to device via sshpass:**

```bash
sshpass -p 'nv' ssh-copy-id -o StrictHostKeyChecking=accept-new nv@192.168.55.1
```

**0.6.3 Verify passwordless access:**

```bash
ssh nv@192.168.55.1 "echo OK"   # should not prompt for password
ssh nv@192.168.55.1 "sudo whoami"   # should print "root"
```

If passwordless SSH fails, check `~/.ssh/authorized_keys` permissions (must be `600`) and
`~/.ssh` permissions (must be `700`) on the device.

**0.6.4 (Optional) Update devel machine SSH config:**

Check if `~/.ssh/config` has a `RemoteCommand` for `192.168.55.1` pointing to an old workspace
path. If so, update it for this device. See `resource/config-ssh-default-folder.md` for template.

---

After step 0.6 completes, all subsequent SSH commands use the same IP (`192.168.55.1`). The mDNS hostname is reserved exclusively for WiFi production operations and should never be used for development SSH connections.

### 1. Install essential packages

```bash
ssh nv@192.168.55.1 "bash -lc 'sudo apt-get update -qq && sudo apt-get install -y tmux curl git'"
```

### 1.1. Install `uv` (Python package manager)

The orchestrator CLI uses `uv` for all entry points (`uv run devel`, `uv run prod`, etc.).

```bash
ssh nv@192.168.55.1 "bash -lc 'curl -fsSL https://astral.sh/uv/install.sh | bash'"
```

After installation, ensure `~/.local/bin` is in `PATH` (the install script adds it to
`~/.profile`). Verify:

```bash
ssh nv@192.168.55.1 "bash -lc 'source ~/.profile && uv --version'"
```

### 1.2. Configure LiDAR wired interface (eth0)

The MID360 LiDAR connects via Ethernet and requires a static IP on the `192.168.2.0/24`
subnet (as configured in `src/bringup/config/mid360.json`).

```bash
ssh nv@192.168.55.1 "sudo nmcli connection add \
    type ethernet con-name 'Livox-LiDAR' ifname eth0 \
    ipv4.method manual \
    ipv4.addresses 192.168.2.50/24 \
    connection.autoconnect yes"
```

Verify the interface is up:

```bash
ssh nv@192.168.55.1 "ip addr show eth0 2>&1 | grep 'inet '"
```

Expected output: `inet 192.168.2.50/24 brd 192.168.2.255 ...`

### 1.3. Configure dual-path network routing

The USB RNDIS link (`192.168.55.1` via `l4tbr0`) provides a low-latency wired
connection for bulk data transfer. WiFi (`wlan0`) provides general SSH access
via mDNS hostname resolution.

The `c5pro` orchestrator auto-detects the USB link at runtime:
- `uv run integration` commands (sync/build/full/increment/check) **prefer USB**
  for fast rsync and SSH
- `uv run prod` and `uv run viz` always use `192.168.55.1` (USB IP) for
  connectivity

**1.3.1 Ensure USB hosts entry (devel machine):**

Add a fallback hosts entry so SSH can reach the device via USB IP directly
when WiFi is not available or mDNS has not yet been configured:

```bash
echo '192.168.55.1 nv-{DEVICE}' | sudo tee -a /etc/hosts
```

**1.3.2 Restrict mDNS to wlan0 (Jetson):**

After WiFi is connected and working (Step 1.5), limit `avahi-daemon` to only
publish on `wlan0`. This ensures `nv-{DEVICE}.local` always resolves to the WiFi IP,
preventing ethernet interface IPs (eth0, l4tbr0) from leaking into mDNS:

```bash
ssh nv@192.168.55.1 "sudo sed -i '/^\[server\]/a allow-interfaces=wlan0' /etc/avahi/avahi-daemon.conf && sudo systemctl restart avahi-daemon"
```

If WiFi is not yet available, skip this step — the USB fallback path covers
connectivity until WiFi is operational.

**1.3.3 Verify routing:**

```bash
# mDNS should resolve to a wireless IP (not 192.168.55.1 or 192.168.2.50)
avahi-resolve-host-name nv-{DEVICE}.local

# USB link should respond with low latency
ping -c1 -W1 192.168.55.1

# Integration CLI should auto-detect USB
uv run integration check
```

### 1.5. Lock WiFi to Diff* SSID

Lock wlan0 to only connect to a single SSID matching `Diff*` (e.g. `DiffRobot（5G）`) with
password `888888888`. All other WiFi connection profiles are removed, and a NetworkManager
dispatcher script prevents any non-Diff* connection from staying active.

**1.5.1 Delete all non-Diff WiFi connections:**

> ⚠️ Only deletes WiFi (`802-11-wireless`) connections. Wired Ethernet profiles
> (required for LiDAR communication in Step 1.2) are left untouched.

```bash
ssh nv@192.168.55.1 "bash -lc '
# Delete all non-Diff WiFi connections (need sudo)
for uuid in \$(nmcli -t -f TYPE,UUID connection show | grep ^802-11-wireless | grep -v DiffRobot | cut -d: -f2); do
    sudo nmcli connection delete \"\$uuid\"
done
# Delete the old DiffRobot profile if it existed (will be recreated below)
sudo nmcli connection delete DiffRobot 2>/dev/null || true
'"
```

**1.5.2 Create DiffRobot connection with strict settings:**

```bash
ssh nv@192.168.55.1 "bash -lc '
sudo nmcli connection add \
    type wifi \
    con-name DiffRobot \
    ifname wlan0 \
    ssid DiffRobot（5G） \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk 888888888 \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    connection.auth-retries 0 \
    802-11-wireless.powersave 2
'"
```

**1.5.3 Install dispatcher script to reject non-Diff* WiFi:**

```bash
cat <<'SCRIPTEOF' | ssh nv@192.168.55.1 "sudo tee /etc/NetworkManager/dispatcher.d/91-wifi-lock > /dev/null && sudo chmod +x /etc/NetworkManager/dispatcher.d/91-wifi-lock"
#!/usr/bin/env bash
IFACE="$1" ACTION="$2"

if [ "$IFACE" != "wlan0" ]; then exit 0; fi

if [ "$ACTION" = "up" ]; then
    CXN=$(nmcli -t -f GENERAL.CONNECTION device show wlan0 2>/dev/null | cut -d: -f2)
    if [[ "$CXN" != Diff* ]]; then
        logger -t wifi-lock "Rejecting SSID=$CXN (not Diff*)"
        nmcli device disconnect wlan0
    fi
fi
SCRIPTEOF
```

**1.5.4 Verify WiFi lock:**

```bash
ssh nv@192.168.55.1 "bash -lc '
echo \"=== WiFi profiles ===\"; nmcli -t -f NAME connection show | grep -i diff
echo \"\"; echo \"=== WiFi autoconnect ===\"; nmcli -t -f NAME,AUTOCONNECT connection show | grep DiffRobot
echo \"\"; echo \"=== Dispatcher ===\"; ls -la /etc/NetworkManager/dispatcher.d/91-wifi-lock
echo \"\"; echo \"=== Connected SSID ===\"; nmcli -t -f GENERAL.CONNECTION device show wlan0
echo \"\"; echo \"=== Settings ===\"; nmcli -t -f connection.autoconnect,connection.autoconnect-priority,802-11-wireless.powersave connection show DiffRobot
'"
```

### 2. Configure NTP time sync via wlan0

pool.ntp.org DNS is intercepted by the host proxy (Clash), so explicit NTP servers are
required. The USB link (`l4tbr0`) has a lower route metric than wlan0, so static `/32` routes
force NTP traffic through wlan0.

**2.1 Write systemd-timesyncd configuration:**

```bash
cat <<'CONFEOF' | ssh nv@192.168.55.1 "sudo tee /etc/systemd/timesyncd.conf > /dev/null"
[Time]
NTP=ntp.ubuntu.com ntp.aliyun.com
FallbackNTP=ntp.ubuntu.com ntp.aliyun.com
CONFEOF
```

**2.2 Create NetworkManager dispatcher for persistent wlan0 routing:**

```bash
cat <<'SCRIPTEOF' | ssh nv@192.168.55.1 "sudo tee /etc/NetworkManager/dispatcher.d/90-ntp-via-wlan0 > /dev/null && sudo chmod +x /etc/NetworkManager/dispatcher.d/90-ntp-via-wlan0"
#!/usr/bin/env bash
IFACE="$1" ACTION="$2"

if [ "$IFACE" = "wlan0" ] && [ "$ACTION" = "up" ]; then
    WLAN_GW=$(ip route show default dev wlan0 | awk '{print $3}')
    for ip in 185.125.190.58 185.125.190.56 185.125.190.57 91.189.91.157 203.107.6.88; do
        ip route replace $ip/32 via $WLAN_GW dev wlan0 2>/dev/null
    done
fi
SCRIPTEOF
```

**2.3 Add routes immediately and restart timesyncd:**

```bash
ssh nv@192.168.55.1 "bash -lc '
WLAN_GW=\$(ip route show default dev wlan0 | awk \"{print \\\$3}\")
for ip in 185.125.190.58 185.125.190.56 185.125.190.57 91.189.91.157 203.107.6.88; do
    sudo ip route add \$ip/32 via \$WLAN_GW dev wlan0 2>/dev/null || true
done
sudo systemctl restart systemd-timesyncd
'"
```

**2.4 Verify sync:**

```bash
ssh nv@192.168.55.1 "bash -lc 'timedatectl status'"
```

Look for `System clock synchronized: yes`. If it shows `no`, wait a few seconds and repeat.

### 3. Configure tmux (mouse on)

```bash
ssh nv@192.168.55.1 "bash -lc 'echo \"set -g mouse on\" > ~/.tmux.conf'"
```

New tmux sessions will have mouse mode enabled. Existing sessions are unaffected.

### 4. Change default shell to bash

```bash
ssh nv@192.168.55.1 "sudo chsh -s /bin/bash nv"
```

Changes take effect on next login (new SSH session or tmux pane). The current user (`nv`)
shell is changed from zsh to bash.

### 5. Install oh-my-bash

```bash
ssh nv@192.168.55.1 "bash -lc 'bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)\" --unattended'"
```

The `--unattended` flag prevents dropping into a new Bash session after install. Oh-my-bash
backups the original `~/.bashrc` to `~/.bashrc.pre-oh-my-bash`.

### 6. Set default SSH working directory (device-side)

Appends a `cd` to the workspace to `~/.profile`. Since `.profile` is only read by login
shells (i.e. interactive SSH), this does not affect tmux panes or other non-login sessions.

See also `resource/config-ssh-default-folder.md` for the complementary **devel machine** SSH
config approach (using `RemoteCommand`).

```bash
ssh nv@192.168.55.1 "bash -lc 'echo \"\" >> ~/.profile && echo \"# Auto-cd to workspace on SSH login\" >> ~/.profile && echo \"cd /home/nv/ros1-yopo\" >> ~/.profile'"
```

### 7. Install Livox SDK2 (static library and headers)

`livox_ros_driver2` requires the bundled Livox SDK. The device may have an older
version installed — always run the install script to ensure version match (drivers
may reference newer enum values like `kLivoxLidarTypeMid360s`).

**Important**: `rsync` excludes `*.so` files, so the shared library must be copied
separately if it wasn't bundled in the repo. The install script handles this.

**7.1 Install from bundled pre-built SDK:**

```bash
ssh nv@192.168.55.1 "bash -lc 'cd /home/nv/ros1-yopo && bash .agents/skills/setup-device/livox_sdk_install.sh'"
```

The script copies headers and static library to `/usr/local/`. If the shared
library (`liblivox_lidar_sdk_shared.so`) was excluded by rsync, copy it manually:

```bash
scp .agents/skills/setup-device/livox_sdk/liblivox_lidar_sdk_shared.so nv@192.168.55.1:/tmp/
ssh nv@192.168.55.1 "sudo cp /tmp/liblivox_lidar_sdk_shared.so /usr/local/lib/ && sudo ldconfig"
```

**7.2 Verify correct version:**

```bash
ssh nv@192.168.55.1 "grep 'kLivoxLidarTypeMid360s' /usr/local/include/livox_lidar_def.h"
```

Expected output includes `kLivoxLidarTypeMid360s = 35`. If the enum is missing,
the SDK was not updated — rerun the install and verify rsync did not exclude
the header files.

These files were pre-compiled on an identical {DEVICE} Jetson (aarch64, JetPack).
If the architecture differs, build from source instead:

```bash
ssh nv@192.168.55.1 "bash -lc '
cd /tmp &&
git clone https://github.com/Livox-SDK/Livox-SDK2.git &&
cd Livox-SDK2 &&
mkdir -p build && cd build &&
cmake .. && make -j\$(nproc) &&
sudo make install
'"
```

### 8. Sync code to device

After all setup steps complete, deploy the workspace from devel machine to the device:

```bash
uv run integration sync
```

This rsyncs the repository to `/home/nv/ros1-yopo` on the device. After sync,
SSH login automatically enters the workspace (configured in Step 6).

Verify the workspace is in place:

```bash
ssh nv@192.168.55.1 "bash -lc 'ls -la ~/ros1-yopo/pyproject.toml'"
```

## Verification

| Step | Command | Expected Result |
|------|---------|-----------------|
| mDNS route | `avahi-resolve-host-name nv-{DEVICE}.local` | wireless IP (not 192.168.55.1 or 192.168.2.50) |
| USB link | `ping -c1 -W1 192.168.55.1` | 0% packet loss, low latency |
| integration routing | `uv run integration check` | `USB (192.168.55.1)` in output |
| SSH key | `ssh nv@192.168.55.1 "echo OK"` | `OK` (no password prompt) |
| tmux | `ssh nv@192.168.55.1 "bash -lc 'tmux -V'"` | `tmux 3.0a` |
| NTP | `ssh nv@192.168.55.1 "bash -lc 'timedatectl show --property=NTPSynchronized --value'"` | `yes` |
| NTP route | `ssh nv@192.168.55.1 "bash -lc 'ip route get 185.125.190.58'"` | `via 192.168.110.1 dev wlan0` |
| tmux config | `ssh nv@192.168.55.1 "bash -lc 'cat ~/.tmux.conf'"` | `set -g mouse on` |
| Shell | `ssh nv@192.168.55.1 "bash -lc 'echo \$SHELL'"` | `/bin/bash` |
| oh-my-bash | `ssh nv@192.168.55.1 "bash -lc 'head -3 ~/.bashrc'"` | References `oh-my-bash` |
| WiFi locked | `ssh nv@192.168.55.1 "bash -lc 'nmcli -t -f TYPE connection show | grep 802-11 | wc -l'"` | `1` (only DiffRobot) |
| WiFi lock dispatcher | `ssh nv@192.168.55.1 "bash -lc 'test -x /etc/NetworkManager/dispatcher.d/91-wifi-lock && echo YES'"` | `YES` |
| LiDAR eth0 | `ssh nv@192.168.55.1 "bash -lc 'ip addr show eth0 | grep \\\"inet 192.168.2\\\"'"` | `192.168.2.50/24` |
| SSH working dir | `ssh -t nv@192.168.55.1 'bash -l -c pwd'` | `/home/nv/ros1-yopo` |

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `nv-{DEVICE}.local` not resolving | avahi-daemon not installed/running on device | Run Step 0.5; `sudo systemctl enable --now avahi-daemon` |
| `nv-{DEVICE}.local` not resolving from devel machine | avahi-daemon not installed on devel machine | `sudo apt-get install -y avahi-daemon` on devel machine |
| `ssh: Could not resolve hostname nv-{DEVICE}.local` | mDNS not configured yet; wrong hostname | Use IP directly (Step 0); verify hostname is `nv-{DEVICE}` (Step 0.5.2) |
| SSH prompts for password despite key deploy | wrong key or permissions | Check `~/.ssh/authorized_keys` (600) and `~/.ssh` (700) on device |
| `sshpass: command not found` | sshpass not installed locally | `sudo apt-get install -y sshpass` |
| NTP not syncing | DNS intercepting pool.ntp.org | Use `ntp.ubuntu.com` or `ntp.aliyun.com` as in step 2.1 |
| NTP traffic via `l4tbr0` | No static route for NTP IPs | Check dispatcher script, rerun step 2.3 |
| `timedatectl` shows "no" | NTP needs time to poll | Wait 30s and recheck; adjust `PollIntervalMinSec` |
| oh-my-bash install fails | `curl` not installed | Run step 1 first |
| `chsh` fails | Invalid shell path | Verify `/bin/bash` exists |
| tmux config not applied | Existing session | New sessions pick up config; old ones need `tmux source ~/.tmux.conf` |
| Device connects to random WiFi | Dispatcher not executing | Check `ls -la /etc/NetworkManager/dispatcher.d/91-wifi-lock`: must be executable; check `journalctl -u NetworkManager -g wifi-lock` |
| WiFi keeps reconnecting | Powersave causing disconnects | Verify `nmcli -t -f 802-11-wireless.powersave connection show DiffRobot` shows `2` |
| `find_library: liblivox_lidar_sdk_static.a` not found | Livox SDK not installed | Run `bash .agents/skills/setup-device/livox_sdk_install.sh` on device |
| `bind failed` / `Create detection socket failed` | eth0 missing IP `192.168.2.50` (wired profile deleted) or previous livox process still holds UDP port | `sudo nmcli con up Livox-LiDAR` to restore IP; `pkill -f livox 2>/dev/null` to clear stale socket |
| integration goes via WiFi instead of USB | USB cable disconnected or `192.168.55.1` unreachable | Connect USB-C cable; run `uv run integration check` to verify routing via USB |
| `nv-{DEVICE}.local` resolves to wrong IP (e.g. `192.168.2.50` or `172.17.0.1`) instead of WiFi IP | Process contention on port 5353 (mDNS) -- typically `nxserver.bin` (NoMachine) advertising on all interfaces | See `resource/mDNS-debug.md` |
| wlan0 cannot associate with Diff* SSID (`ASSOC-REJECT status_code=1`, `nl80211: kernel reports: Authentication algorithm number required`) | NVIDIA BSP `rtl8822ce` driver has incomplete nl80211 auth support | Run `resource/fix-rtw88-wifi.sh` to replace with lwfinger/rtw88 driver |
