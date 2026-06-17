#!/usr/bin/env bash
#
# Replace NVIDIA BSP rtl8822ce (broken nl80211 auth) with lwfinger/rtw88.
#
# The NVIDIA-provided rtl8822ce driver fails WPA2-PSK association on 5 GHz with:
#   nl80211: kernel reports: Authentication algorithm number required
#   wlan0: CTRL-EVENT-ASSOC-REJECT status_code=1
#
# This script clones lwfinger/rtw88, builds it, blacklists the old driver,
# and loads the replacement.  Idempotent.
#
# Prerequisites (checked at runtime): git, make, gcc, kernel headers
# Internet access (via USB RNDIS proxy or wlan) for the git clone.
#
# Usage from devel machine (repo already synced):
#   ssh nv@192.168.55.1 \
#     "bash -lc 'cd /home/nv/ros1-yopo && \
#       bash .agents/skills/setup-device/resource/fix-rtw88-wifi.sh'"
#
# Without repo on device (pipe via SSH):
#   cat .agents/skills/setup-device/resource/fix-rtw88-wifi.sh \
#     | ssh nv@192.168.55.1 "bash -s"

set -euo pipefail

# ---- helpers ----------------------------------------------------------

info()  { printf "[fix-rtw88] %s\n" "$*"; }
err()   { printf "[fix-rtw88] ERROR: %s\n" "$*" >&2; exit 1; }

# ---- prerequisites ----------------------------------------------------

for c in git make gcc; do
  command -v "$c" &>/dev/null || err "$c not found – install build-essential git first"
done

KVER="$(uname -r)"
KH="/lib/modules/$KVER/build"
if ! [ -f "$KH/Makefile" ]; then
  err "kernel build tree not found at $KH – install linux-headers-$KVER"
fi
info "kernel $KVER, build tree OK"

# ---- already installed? -----------------------------------------------

if modinfo rtw_8822ce &>/dev/null; then
  info "rtw_8822ce already installed, nothing to do"
  exit 0
fi

# ---- clone & build ----------------------------------------------------

TMPDIR="$(mktemp -d /tmp/rtw88-build.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

info "cloning lwfinger/rtw88 …"
git clone --depth=1 https://github.com/lwfinger/rtw88.git "$TMPDIR" 2>&1

info "building …"
make -C "$TMPDIR" -j"$(nproc)"

# ---- install ----------------------------------------------------------

info "installing modules …"
sudo make -C "$TMPDIR" install

info "installing firmware …"
sudo make -C "$TMPDIR" install_fw

# ---- persist ----------------------------------------------------------

echo "blacklist rtl8822ce" | sudo tee /etc/modprobe.d/blacklist-rtl8822ce.conf >/dev/null
echo "rtw_8822ce"          | sudo tee /etc/modules-load.d/rtw88.conf        >/dev/null
sudo depmod -a

# ---- switch driver ----------------------------------------------------

if lsmod | grep -q "^rtl8822ce"; then
  sudo rmmod rtl8822ce
  info "old driver unloaded"
fi

sudo modprobe rtw_8822ce
info "rtw_8822ce loaded"

sudo ip link set wlan0 up 2>/dev/null || true

info "done. verify with: lsmod | grep rtw_8822ce && iw dev wlan0 link"
