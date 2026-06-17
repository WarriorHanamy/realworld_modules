---
name: nv-network-proxy
description: Route NVIDIA Jetson (nv@192.168.55.1) internet through host USB link via transparent proxy. No proxy env required on NV — all TCP/DNS traffic is silently redirected through Clash on host.
---

# NV Network Proxy — Transparent Mode

NV device needs **zero proxy configuration**. All TCP and DNS traffic is redirected transparently on the host via `redir-port` and `iptables-native` REDIRECT rules.

## Network Topology

```
                    USB/RNDIS (192.168.55.0/24)
  ┌────────┐     enp17s0u2 (192.168.55.100)     l4tbr0     ┌──────────┐
  │  Host  │◄──────────────────────────────────────────────►│  NV Dev  │
  │  Arch  │                                                │  Ubuntu  │
  └───┬────┘                                                └──────────┘
      │ enp6s0 (WAN, metric 100)
  ┌───▼────┐
  │Internet│
  └────────┘
  Proxy: mihomo (Clash) :7890
  redir-port: 7893
  DNS proxy: 0.0.0.0:5334
```

## Traffic Flow

```
NV TCP 80/443 → USB → Host PREROUTING REDIRECT :7893 → Clash redir-port → proxy exit
NV UDP 53    → USB → Host PREROUTING REDIRECT :5334 → Clash DNS (fake-ip)  → proxy exit
NV other     → USB → Host POSTROUTING MASQUERADE   → enp6s0 NAT → direct exit
```

## Pre-flight

> **Why `hostname.local` and not a static IP?** The USB/RNDIS link always
> assigns `192.168.55.1` to the remote device. If you swap Jetson units,
> the IP stays the same but the device identity (hostname, SSH host key)
> changes. Hard-coding `192.168.55.1` in `/etc/hosts` or scripts masks
> this swap. Use mDNS (`.local`) — each device broadcasts its own name
> dynamically.

```bash
ssh nv@nv-V25.local "echo OK"           # passwordless SSH via mDNS
ss -tlnp | grep -E ':789[03]'           # Clash mixed+redir ports
ip addr show enp17s0u2                  # USB host interface
```

## Setup

### 1. Clash — Enable redir-port + DNS

Edit `~/.config/mihomo-party/work/config.yaml`:

```yaml
dns:
  listen: 0.0.0.0:5334          # was 127.0.0.1:5334
redir-port: 7893                # was 0
```

Restart sidecar (SIGHUP `pidof mihomo`), verify:

```bash
ss -tlnp | grep -E ':7893|:5334'
```

### 2. Host — Enable IP Forwarding

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-nv-usb-forward.conf
sudo sysctl -p /etc/sysctl.d/99-nv-usb-forward.conf
```

### 3. Host — nftables REDIRECT + MASQUERADE

Apply immediately:

```bash
# REDIRECT TCP (except SSH) to Clash redir-port
sudo nft add rule ip nat PREROUTING \
  ip saddr 192.168.55.0/24 tcp dport != 22 redirect to :7893

# REDIRECT DNS to Clash DNS
sudo nft add rule ip nat PREROUTING \
  ip saddr 192.168.55.0/24 udp dport 53 redirect to :5334

# MASQUERADE fallback (non-proxy traffic)
sudo nft add rule ip nat POSTROUTING \
  oifname enp6s0 ip saddr 192.168.55.0/24 masquerade

# FORWARD allow USB ↔ WAN
sudo nft add rule ip filter FORWARD \
  iifname enp17s0u2 oifname enp6s0 ct state new,established accept
sudo nft add rule ip filter FORWARD \
  iifname enp6s0 oifname enp17s0u2 ct state established,related accept
```

### 4. Host — UFW Allow USB Interface

```bash
sudo ufw allow in on enp17s0u2
```

### 5. Host — Persist Rules

```bash
sudo install -Dm755 /usr/local/libexec/nv-usb-forward.sh /dev/null
```

Write to `/usr/local/libexec/nv-usb-forward.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# NAT PREROUTING: transparent proxy REDIRECT
nft list chain ip nat PREROUTING | grep -q 'redirect to :7893' || \
  nft add rule ip nat PREROUTING \
    ip saddr 192.168.55.0/24 tcp dport != 22 redirect to :7893

nft list chain ip nat PREROUTING | grep -q 'redirect to :5334' || \
  nft add rule ip nat PREROUTING \
    ip saddr 192.168.55.0/24 udp dport 53 redirect to :5334

# NAT POSTROUTING: MASQUERADE fallback
nft list chain ip nat POSTROUTING | grep -q 'enp6s0.*masquerade' || \
  nft add rule ip nat POSTROUTING \
    oifname enp6s0 ip saddr 192.168.55.0/24 masquerade

# FORWARD: allow USB ↔ WAN
nft list chain ip filter FORWARD | grep -q 'enp17s0u2.*established.*accept' || \
  nft add rule ip filter FORWARD \
    iifname enp17s0u2 oifname enp6s0 ct state new,established accept

nft list chain ip filter FORWARD | grep -q 'enp6s0.*enp17s0u2.*established' || \
  nft add rule ip filter FORWARD \
    iifname enp6s0 oifname enp17s0u2 ct state established,related accept
```

```bash
sudo tee /etc/systemd/system/nv-usb-forward.service <<'UNIT'
[Unit]
Description=NV USB NAT and forwarding rules
After=network.target docker.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/nv-usb-forward.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now nv-usb-forward.service
```

### 6. NV Device — Prioritize USB Route

```bash
ssh nv@192.168.55.1 "
  sudo ip route replace default via 192.168.55.100 dev l4tbr0 metric 10
  sudo tee /etc/systemd/system/nv-usb-route.service <<'UNIT'
[Unit]
Description=Prioritize l4tbr0 default route via host
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip route replace default via 192.168.55.100 dev l4tbr0 metric 10
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now nv-usb-route.service
"
```

## Verification

```bash
# NV: no proxy env
ssh nv@192.168.55.1 "env | grep -i proxy || echo 'clean'"

# NV: default route via host
ssh nv@192.168.55.1 "ip route show default"

# Tunnel HTTP
ssh nv@192.168.55.1 "curl -s http://httpbin.org/ip"

# Tunnel HTTPS
ssh nv@192.168.55.1 "curl -s -o /dev/null -w '%{http_code}' https://www.google.com"

# DNS + HTTPS
ssh nv@192.168.55.1 "curl -s -o /dev/null -w '%{http_code}' https://github.com"

# Host: nftables rules active
sudo nft list chain ip nat PREROUTING
sudo nft list chain ip nat POSTROUTING | grep enp6s0
```

## Teardown

```bash
# Host: disable forwarding
sudo rm -f /etc/sysctl.d/99-nv-usb-forward.conf
sudo sysctl -w net.ipv4.ip_forward=0

# Host: remove NAT rules
sudo nft flush chain ip nat PREROUTING
sudo nft flush chain ip nat POSTROUTING
sudo nft flush chain ip filter FORWARD

# Host: remove service
sudo systemctl disable --now nv-usb-forward.service
sudo rm -f /etc/systemd/system/nv-usb-forward.service /usr/local/libexec/nv-usb-forward.sh
sudo systemctl daemon-reload

# Host: remove UFW rule
sudo ufw delete allow in on enp17s0u2

# NV: remove route service
ssh nv@192.168.55.1 "
  sudo systemctl disable --now nv-usb-route.service
  sudo rm -f /etc/systemd/system/nv-usb-route.service
  sudo systemctl daemon-reload
"
```

## Clock Sync

NV device has no accessible hardware clock and DNS is hijacked by Clash fake-ip (`198.18.x.x`), so `ntpd` / `chrony` cannot reach NTP servers.  Time must be pushed from the host.

### One-shot sync

```bash
ssh nv@nv-V25.local "sudo date -s '$(date -u +%Y-%m-%d\ %H:%M:%S)'"
```

### Periodic sync via host crontab

```bash
(crontab -l 2>/dev/null | grep -v 'nv.*date'
 echo '# Push time to nv every hour to prevent clock skew'
 echo '0 * * * * ssh nv@nv-V25.local "sudo date -s \"\$(date -u +%Y-%m-%d\ %H:%M:%S)\"" >/dev/null 2>&1'
) | crontab -
```

Requires `cronie` (Arch) or equivalent on host.

### Verify

```bash
date '+%Y-%m-%d %H:%M:%S %z' && ssh nv@nv-V25.local 'date "+%Y-%m-%d %H:%M:%S %z"'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `iptables -t nat` says incompatible | Native nft and iptables-nft mixed on same table | Use `nft` for all nat table rules |
| Counters increment but curl fails | UFW INPUT blocks redirected traffic | `sudo ufw allow in on enp17s0u2` |
| NV can't reach 192.168.55.100 | l4tbr0 not up | `ssh nv@<hostname>.local 'sudo systemctl start nv-usb-route.service'` |
| port 7893 not listening | Clash config not reloaded | `sudo kill -HUP $(pidof mihomo)` |
| Rules lost after reboot | systemd service not enabled | `sudo systemctl enable --now nv-usb-forward.service` |
| Wrong host connected silently | `/etc/hosts` has `192.168.55.1` hard-coded to old hostname | Remove the entry; use `hostname.local` via mDNS — each device self-identifies |
