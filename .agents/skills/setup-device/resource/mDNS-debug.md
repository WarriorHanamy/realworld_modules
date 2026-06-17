# mDNS Debug: Wrong IP Resolved for nv-{DEVICE}.local

## Symptom

`nv-{DEVICE}.local` resolves to an unexpected IP -- e.g. `192.168.2.50` (LiDAR eth0),
`172.17.0.1` (Docker bridge), or an IPv6 link-local address -- instead of the
WiFi IP (`192.168.110.141`).

SSH via mDNS fails or connects to the wrong interface.

## Diagnostic Steps

**1. Check what currently owns port 5353 (mDNS) on the device:**

```bash
ssh nv@192.168.55.1 "sudo ss -tulpn | grep 5353"
```

Expected output: only `avahi-daemon` entries.

```
udp   UNCONN  ...  0.0.0.0:5353      users:(("avahi-daemon",pid=XXXX,fd=XX))
udp   UNCONN  ...        *:5353      users:(("avahi-daemon",pid=XXXX,fd=XX))
```

If a second process (e.g. `nxserver.bin`, `named`, `dnsmasq`) also shows up on
port 5353, **that process is providing conflicting mDNS answers**.

**2. Check avahi hostname registration:**

```bash
ssh nv@192.168.55.1 "systemctl status avahi-daemon --no-pager | head -8"
```

Look for the hostname after `running [` e.g.:

- `running [nv-{DEVICE}.local]` -- correct
- `running [nv-{DEVICE}-2.local]` -- conflict detected, avahi fell back to a different name

**3. Resolve from the device itself to confirm the correct IP:**

```bash
ssh nv@192.168.55.1 "avahi-resolve-host-name -4 nv-{DEVICE}.local"
```

Expected: `192.168.110.141` (WiFi IP). If this also gives the wrong IP,
the device-side mDNS stack is the problem.

**4. Check devel machine resolution:**

```bash
avahi-resolve-host-name -4 nv-{DEVICE}.local
```

Use `-4` to force IPv4. Without it, `getent hosts` / `avahi-resolve-host-name`
may prefer a stale IPv6 link-local record (`fe80::...`) over IPv4.

**5. Reverse resolve the WiFi IP to confirm bidirectional correctness:**

```bash
avahi-resolve-address 192.168.110.141
```

Must return `nv-{DEVICE}.local`.

## Root Cause

The most common cause is **NoMachine (`nxserver.bin`)** listening on port 5353
on **all** network interfaces:

```
udp   UNCONN  8448  0  192.168.2.50:5353    users:(("nxserver.bin",pid=1436,fd=XX))
udp   UNCONN  8448  0  172.17.0.1:5353      users:(("nxserver.bin",pid=1436,fd=XX))
udp   UNCONN  8448  0  192.168.55.1:5353    users:(("nxserver.bin",pid=1436,fd=XX))
udp   UNCONN  5888  0  0.0.0.0:5353         users:(("nxserver.bin",pid=1436,fd=XX))
```

nxserver advertises the device hostname via mDNS for remote desktop discovery.
It responds on **every interface**, including eth0 (`192.168.2.50`) which is
the LiDAR-only subnet not reachable from the devel machine's WiFi. The devel
machine's avahi-daemon caches whichever response arrives first (typically from
eth0).

This causes three problems:

| Problem | Why |
|---|---|
| Resolves to `192.168.2.50` | nxserver responds with eth0 IP; devel machine caches it |
| avahi registers as `nv-{DEVICE}-2.local` | nxserver already claimed `nv-{DEVICE}.local` on the network |
| Stale cache on devel machine | Old cached record persists even after restarting avahi-daemon |

Other processes known to cause similar conflicts: `dnsmasq`, `systemd-resolved`
(with `mDNS=yes`), manual mDNS responders.

## Fix

**1. Stop and disable NoMachine (nxserver) -- not needed for drone operations:**

```bash
ssh nv@192.168.55.1 "\
  sudo systemctl stop nxserver && \
  sudo systemctl disable nxserver"
```

**2. Restart avahi-daemon so it re-registers `nv-{DEVICE}.local` cleanly:**

```bash
ssh nv@192.168.55.1 "sudo systemctl restart avahi-daemon"
```

**3. Clear devel machine mDNS cache:**

```bash
sudo systemctl restart avahi-daemon
sleep 2
```

## Verification

```bash
# Device-side: only avahi on port 5353
ssh nv@192.168.55.1 "sudo ss -tulpn | grep 5353"

# Device-side: hostname without -2 suffix
ssh nv@192.168.55.1 "systemctl status avahi-daemon --no-pager | head -8"
# → running [nv-{DEVICE}.local]

# Device-side: resolve to WiFi IP
ssh nv@192.168.55.1 "avahi-resolve-host-name -4 nv-{DEVICE}.local"
# → 192.168.110.141

# Devel-side: resolve to WiFi IP
avahi-resolve-host-name -4 nv-{DEVICE}.local
# → 192.168.110.141

# SSH via mDNS works
ssh -o ConnectTimeout=5 nv@nv-{DEVICE}.local "echo OK"
# → OK
```
