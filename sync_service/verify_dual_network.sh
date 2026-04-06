#!/usr/bin/env bash
#
# Verify dual network Syncthing configuration
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo "=== Dual Network Syncthing Verification ==="
echo ""

# Load environment
fn_nv_load_env

# Stage 1: Environment Configuration
echo "1. Environment Configuration"
if [[ -n "${DEVICE_NAME:-}" ]]; then
    pass "DEVICE_NAME: ${DEVICE_NAME}"
else
    warn "DEVICE_NAME not set"
fi

if [[ -n "${DEVICE_IP:-}" ]]; then
    pass "DEVICE_IP: ${DEVICE_IP}"
else
    fail "DEVICE_IP not set"
fi

if [[ -n "${DEVICE_USER:-}" ]]; then
    pass "DEVICE_USER: ${DEVICE_USER}"
else
    fail "DEVICE_USER not set"
fi

echo ""

# Stage 2: Network Connectivity
echo "2. Network Connectivity"

# Check wired connection
if ping -c1 -W1 "${DEVICE_IP}" &>/dev/null; then
    pass "Wired connection to ${DEVICE_IP}"
else
    fail "Wired connection to ${DEVICE_IP}"
fi

# Check WiFi IP if available
if [[ -n "${DEVICE_WIFI_IP:-}" ]]; then
    if ping -c1 -W1 "${DEVICE_WIFI_IP}" &>/dev/null; then
        pass "WiFi connection to ${DEVICE_WIFI_IP}"
    else
        fail "WiFi connection to ${DEVICE_WIFI_IP}"
    fi
else
    warn "DEVICE_WIFI_IP not set (run setup-syncthing.sh to discover)"
fi

# Check mDNS if configured
if [[ -n "${DEVICE_NAME:-}" ]]; then
    if ping -c1 -W2 "${DEVICE_NAME}.local" &>/dev/null; then
        pass "mDNS resolution: ${DEVICE_NAME}.local"
    else
        warn "mDNS resolution failed for ${DEVICE_NAME}.local"
    fi
fi

echo ""

# Stage 3: Network Interfaces
echo "3. Network Interfaces"

# Host interfaces
if ip link show enp17s0u2 &>/dev/null; then
    pass "Host wired interface (enp17s0u2) exists"
else
    warn "Host wired interface (enp17s0u2) not found"
fi

if ip link show wlan0 &>/dev/null; then
    pass "Host WiFi interface (wlan0) exists"
else
    warn "Host WiFi interface (wlan0) not found"
fi

# Device interfaces (via SSH)
fn_nv_ensure_ssh &>/dev/null || true

if "${SSH_CMD[@]}" "ip link show l4tbr0" &>/dev/null; then
    pass "Device wired interface (l4tbr0) exists"
else
    warn "Device wired interface (l4tbr0) not found"
fi

if "${SSH_CMD[@]}" "ip link show wlP1p1s0" &>/dev/null; then
    pass "Device WiFi interface (wlP1p1s0) exists"
else
    warn "Device WiFi interface (wlP1p1s0) not found"
fi

echo ""

# Stage 4: Services
echo "4. Services"

# Syncthing
if systemctl --user is-active syncthing &>/dev/null; then
    pass "Syncthing running on host"
else
    fail "Syncthing not running on host"
fi

# avahi-daemon on device
if "${SSH_CMD[@]}" "systemctl is-active avahi-daemon" &>/dev/null; then
    pass "avahi-daemon running on device"
else
    warn "avahi-daemon not running on device"
fi

echo ""

# Stage 5: Syncthing Connection
echo "5. Syncthing Connection"

# Get API key
API_KEY=$(grep -oP '(?<=<apikey>)[^<]+' "${HOME}/.config/syncthing/config.xml" 2>/dev/null || echo "")

if [[ -n "${API_KEY}" ]]; then
    # Check API responsiveness
    if curl -s -H "X-API-Key: ${API_KEY}" "http://localhost:8384/rest/system/status" | grep -q '"myID"'; then
        pass "Syncthing API responsive"
        
        # Check connections
        CONNECTIONS=$(curl -s -H "X-API-Key: ${API_KEY}" "http://localhost:8384/rest/system/connections" 2>/dev/null)
        
        if echo "${CONNECTIONS}" | grep -q '"connected":true'; then
            pass "Syncthing connected to device"
            
            # Show connection details
            echo ""
            echo "Connection details:"
            echo "${CONNECTIONS}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for conn in data.get('connections', {}).values():
        if conn.get('connected'):
            print(f\"  Address: {conn.get('address', 'unknown')}\")
            print(f\"  Type: {conn.get('type', 'unknown')}\")
            print(f\"  Connected: {conn.get('connected')}\")
except:
    pass
" 2>/dev/null || true
        else
            warn "Syncthing not connected to device"
        fi
    else
        fail "Syncthing API not responsive"
    fi
else
    warn "Could not read Syncthing API key"
fi

echo ""

# Summary
echo "=== Verification Complete ==="
echo ""
echo "Next steps:"
echo "1. If any checks failed, review the logs"
echo "2. For connection issues, check: journalctl --user -u syncthing -f"
echo "3. For network issues, check: ip route show"
echo "4. For mDNS issues, check: systemctl status avahi-daemon"
echo ""