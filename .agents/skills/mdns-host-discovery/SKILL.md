---
name: mdns-host-discovery
description: Use when discovering hostname-IP mappings on a LAN without DNS, when .local name resolution fails, when diagnosing mDNS/Avahi/Bonjour issues, or when needing to set up mDNS on a remote host via SSH.
---

# mDNS Host Discovery

## Overview

mDNS (Multicast DNS) lets hosts on the same link resolve `hostname.local` -- IP without a central DNS server. It uses multicast to `224.0.0.251:5353`, TTL=1, so it never crosses routers or subnets.

- Linux: `avahi-daemon`, macOS: `Bonjour` (built-in), Windows: `mDNSResponder` / Bonjour SDK

## Discovery Pipeline

```
Requester                       224.0.0.251:5353                    Target
   |                                |                                 |
   |-- "who is dwl.local?" ---------|-(multicast to whole LAN)------->|
   |                                |                                 | (daemon listening)
   |                                |<--- "I am dwl.local, IP=..." --|
   |<-- 192.168.1.5 ----------------|                                 |
```

Reverse query (IP -- hostname):

```
   |-- "who has 192.168.1.5?" -----|-(multicast)-------------------->|
   |                                |<--- "dwl.local" ---------------|
```

## Prerequisites (ALL must hold)

| Layer     | Condition                                                | Check                                    |
| --------- | -------------------------------------------------------- | ---------------------------------------- |
| L2        | Same broadcast domain / VLAN (TTL=1 never routed)        | `ip route get 224.0.0.251`               |
| Wi-Fi AP  | No client isolation (AP isolation blocks peer traffic)   | `avahi-browse -art` empty? suspect AP    |
| Switch    | IGMP snooping not dropping 224.0.0.251 (usually flooded) | Check switch logs / test with tcpdump    |
| Firewall  | UDP 5353 in/out allowed on BOTH hosts                    | `tcpdump -i any port 5353` shows traffic |
| Daemon    | mDNS daemon running on BOTH hosts                        | `systemctl status avahi-daemon`          |
| Service   | Hostname registered with daemon (usually automatic)      | `hostnamectl` or `/etc/hostname`         |

## Quick Reference

| Task                                | Command                                       |
| ----------------------------------- | --------------------------------------------- |
| Check daemon status (local)         | `systemctl status avahi-daemon`               |
| Start / enable daemon               | `sudo systemctl enable --now avahi-daemon`    |
| Browse all .local names on LAN      | `avahi-browse -art`                           |
| Resolve hostname -- IP              | `avahi-resolve-host-name dwl.local`           |
| Resolve IP -- hostname              | `avahi-resolve-address 192.168.1.5`           |
| Listen to live mDNS traffic         | `tcpdump -n port 5353`                        |
| View local hostname being advertised | `hostnamectl` or `/etc/avahi/avahi-daemon.conf` |

## Remote Configuration via SSH

When you have SSH access to a target device and need it to participate in mDNS:

### Install & Start avahi

```bash
# Debian / Ubuntu
ssh user@target sudo apt-get install -y avahi-daemon
ssh user@target sudo systemctl enable --now avahi-daemon

# Arch Linux
ssh user@target sudo pacman -S --noconfirm avahi
ssh user@target sudo systemctl enable --now avahi-daemon

# RHEL / Fedora
ssh user@target sudo dnf install -y avahi
ssh user@target sudo systemctl enable --now avahi-daemon
```

### Verify It Works

```bash
ssh user@target systemctl is-active avahi-daemon   # → "active"
ssh user@target avahi-resolve-host-name "$(hostname).local"  # returns its own IP
```

### Override Advertised Hostname (optional)

Default: avahi advertises whatever `hostname` returns. To override:

```bash
ssh user@target sudo tee -a /etc/avahi/avahi-daemon.conf <<'EOF'
[server]
host-name=dwl-box
EOF
ssh user@target sudo systemctl restart avahi-daemon
```

### Open Firewall on Target (if needed)

```bash
# ufw
ssh user@target sudo ufw allow 5353/udp comment 'mDNS'

# firewalld
ssh user@target sudo firewall-cmd --permanent --add-port=5353/udp
ssh user@target sudo firewall-cmd --reload

# iptables (example)
ssh user@target sudo iptables -A INPUT -p udp --dport 5353 -j ACCEPT
```

### One-Liner for Common Distros

```bash
ssh user@target bash -s <<'EOF'
set -e
apt-get install -y avahi-daemon 2>/dev/null || pacman -S --noconfirm avahi 2>/dev/null || dnf install -y avahi 2>/dev/null
systemctl enable --now avahi-daemon
EOF
```

## Troubleshooting

| Symptom                     | Likely Cause                           | Fix                                           |
| --------------------------- | -------------------------------------- | --------------------------------------------- |
| `avahi-browse -art` empty   | AP isolation, firewall, or no daemon   | Check `systemctl`, disable AP isolation       |
| Some hosts visible, some not | Target daemon down or firewalled      | SSH into target, check status and port        |
| `.local` name not resolving | daemon not running, or wrong subnet    | `systemctl status`, confirm same L2 segment   |
| Timeout on resolve          | UDP 5353 blocked on ingress            | `tcpdump` on target to verify packets arrive  |
| Can resolve from macOS but not Linux | macOS Bonjour always on, Linux needs avahi-daemon | Install avahi-daemon on Linux |
| Name resolution slow        | Large LAN, multicast storm             | Usually fine; check for misconfigured switches |

## Common Mistakes

- Assuming mDNS works across VLANs / subnets (TTL=1, never routed)
- Forgetting target side must also run the daemon (mDNS is peer-to-peer, not client-server)
- Overlooking AP/client-isolation on enterprise Wi-Fi — many corporate APs block peer-to-peer multicast by default
- Opening only outbound 5353 on target; mDNS is bidirectional, inbound must be open too
- Assuming `ping dwl` works without `.local` suffix — mDNS only resolves names ending in `.local`
- Hard-coding device hostnames in `/etc/hosts` for point-to-point links
   (e.g. USB/RNDIS `192.168.55.1 nv-{DEVICE}`). The IP stays constant across
  reboots and device swaps, but a different device with a different
  hostname and SSH host key will produce silent mismatches. Let mDNS
  alone resolve `.local` names — each device advertises its own identity
  dynamically. Keep `/etc/hosts` clean of such entries.
