# Setup Device

Configure a {DEVICE} Jetson device with core utilities: initial SSH access via IP,
mDNS/avahi-daemon, SSH key deployment, WiFi lock to Diff\* SSID, NTP via wlan0,
tmux, bash, LiDAR wired interface, Livox SDK, and uxrce_dds serial port.

## Prerequisites

- Jetson connected via USB (RNDIS `192.168.55.1`) or on same WiFi
- Default credentials: user `nv`, password `nv`
- Target WiFi SSID matching `Diff*` in range
- Local machine has `sshpass`, `ssh-copy-id`

## Get Device Name

Replace every `{DEVICE}` placeholder with the actual device name.

## Workflows

### 0. Establish SSH access

```bash
sshpass -p 'nv' ssh -o StrictHostKeyChecking=accept-new nv@192.168.55.1 "echo SSH_OK"
```

Fallback: scan WiFi subnet if USB link unavailable.

### 0.5. Configure mDNS

```bash
ssh nv@192.168.55.1 "sudo apt-get install -y avahi-daemon"
ssh nv@192.168.55.1 "sudo hostnamectl set-hostname nv-{DEVICE} && sudo systemctl enable --now avahi-daemon"
```

Verify: `avahi-resolve-host-name nv-{DEVICE}.local`

### 0.6. Deploy SSH keys

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)-$(date +%Y%m%d)"
sshpass -p 'nv' ssh-copy-id -o StrictHostKeyChecking=accept-new nv@192.168.55.1
```

### 1. Install packages

```bash
ssh nv@192.168.55.1 "sudo apt-get update -qq && sudo apt-get install -y tmux curl git"
```

### 1.1. Configure LiDAR wired interface

MID360 LiDAR requires static IP `192.168.2.50/24` on eth0:

```bash
ssh nv@192.168.55.1 "sudo nmcli connection add type ethernet con-name 'Livox-LiDAR' ifname eth0 ipv4.method manual ipv4.addresses 192.168.2.50/24 connection.autoconnect yes"
```

### 1.2. Lock WiFi to Diff* SSID

```bash
ssh nv@192.168.55.1 "sudo nmcli connection delete DiffRobot 2>/dev/null; sudo nmcli connection add type wifi con-name DiffRobot ifname wlan0 ssid 'DiffRobot（5G）' wifi-sec.key-mgmt wpa-psk wifi-sec.psk 888888888 connection.autoconnect yes connection.autoconnect-priority 100 802-11-wireless.powersave 2"
```

Install dispatcher to reject non-Diff* WiFi.

### 2. Configure NTP via wlan0

```bash
ssh nv@192.168.55.1 "sudo tee /etc/systemd/timesyncd.conf > /dev/null <<'EOF'
[Time]
NTP=ntp.ubuntu.com ntp.aliyun.com
FallbackNTP=ntp.ubuntu.com ntp.aliyun.com
EOF
sudo systemctl restart systemd-timesyncd"
```

### 3. tmux, bash, oh-my-bash

```bash
ssh nv@192.168.55.1 "echo 'set -g mouse on' > ~/.tmux.conf && sudo chsh -s /bin/bash nv && bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)\" --unattended"
```

### 4. Set default SSH working directory

```bash
ssh nv@192.168.55.1 "echo 'cd /home/nv/realworld_modules' >> ~/.profile"
```

### 5. Install Livox SDK2

```bash
ssh nv@192.168.55.1 "bash -lc 'cd /home/nv/realworld_modules && bash .agents/skills/setup-device/livox_sdk_install.sh'"
```

### 6. Configure uxrce_dds serial port

PX4 FCU connects via `/dev/ttyTHS1` at 921600 baud. Ensure the user has
permission and the port exists:

```bash
ssh nv@192.168.55.1 "sudo usermod -aG dialout nv && ls -l /dev/ttyTHS1"
```

Expected: `/dev/ttyTHS1` is a character device, user `nv` in `dialout` group.

### 7. Sync code to device

```bash
uv run integration sync
```

## Verification

| Check | Command | Expected |
|-------|---------|----------|
| SSH key | `ssh nv@192.168.55.1 "echo OK"` | `OK` |
| mDNS | `avahi-resolve-host-name nv-{DEVICE}.local` | wireless IP |
| LiDAR eth0 | `ssh nv@192.168.55.1 "ip addr show eth0 \| grep 'inet '"` | `192.168.2.50/24` |
| uxrce_dds port | `ssh nv@192.168.55.1 "ls -l /dev/ttyTHS1"` | crw-rw---- |
| NTP | `ssh nv@192.168.55.1 "timedatectl show --property=NTPSynchronized --value"` | `yes` |
| Livox SDK | `ssh nv@192.168.55.1 "grep 'kLivoxLidarTypeMid360s' /usr/local/include/livox_lidar_def.h"` | `kLivoxLidarTypeMid360s = 35` |
| Workspace | `ssh nv@192.168.55.1 "ls ~/realworld_modules/.git"` | exists |

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|------|
| `nv-{DEVICE}.local` not resolving | avahi-daemon not running | `sudo systemctl enable --now avahi-daemon` on device |
| `bind failed` on Livox SDK | eth0 missing 192.168.2.50 | `sudo nmcli con up Livox-LiDAR` |
| `/dev/ttyTHS1` missing | UART not enabled or TX2 pin conflict | `sudo ls /dev/ttyTH*` to confirm; check L4T device tree |
| dialout group not effective | Need re-login | `newgrp dialout` or reboot |
| NTP not syncing | Route missing for NTP IPs | Check `ip route get 185.125.190.58` |
| `uv run integration sync` fails | USB cable disconnected | Connect USB-C; check `ping 192.168.55.1` |
| WiFi lock not working | Dispatcher not executable | `sudo chmod +x /etc/NetworkManager/dispatcher.d/91-wifi-lock` |
