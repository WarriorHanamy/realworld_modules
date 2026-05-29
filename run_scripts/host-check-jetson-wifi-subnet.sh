#!/usr/bin/env bash
#
# host-check-jetson-wifi-subnet.sh — Verify host and Jetson WiFi are on the same subnet
#
# Runs on the host machine.
# Detects the host WiFi interface IP, retrieves the Jetson wlP1p1s0 IP via SSH,
# and compares whether both are on the same IP subnet.
#
# Exit codes:
#   0  — Subnets match
#   1  — Subnets do not match or unreachable
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../sync_service/common.sh"

if [[ ! -f "${COMMON_SH}" ]]; then
  echo "ERROR: Remote execution helpers not found: ${COMMON_SH}" >&2
  exit 1
fi
source "${COMMON_SH}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
HOST_IFACE=""
JETSON_IFACE="wlP1p1s0"

fct_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Verify that the host and Jetson WiFi interfaces are on the same IP subnet.

Options:
  --host-iface IFACE     Host WiFi interface name (default: auto-detect)
  --jetson-iface IFACE   Jetson WiFi interface name (default: ${JETSON_IFACE})
  -h, --help             Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-iface)
      HOST_IFACE="$2"; shift 2 ;;
    --jetson-iface)
      JETSON_IFACE="$2"; shift 2 ;;
    -h|--help)
      fct_usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      fct_usage >&2
      exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helper: extract network address from an interface CIDR
#   e.g. 192.168.108.4/22 -> 192.168.104.0/22
# ---------------------------------------------------------------------------
fct_calc_network() {
  local cidr="$1"
  python3 -c "
import ipaddress, sys
net = ipaddress.IPv4Interface(sys.argv[1]).network
print(net.with_prefixlen)
" "$cidr"
}

# ---------------------------------------------------------------------------
# Helper: get CIDR from an interface name
# ---------------------------------------------------------------------------
fct_get_iface_cidr() {
  local iface="$1"
  local out
  out=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
  if [[ -z "$out" ]]; then
    return 1
  fi
  echo "$out"
}

# ---------------------------------------------------------------------------
# Auto-detect host WiFi interface
# ---------------------------------------------------------------------------
fct_detect_host_wifi_iface() {
  local candidates=($(ip -o link show up 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | grep -E '^(wl|wlan)'))

  # Additional fallback: check iw dev for wireless interfaces
  if [[ ${#candidates[@]} -eq 0 ]]; then
    local iw_candidates=($(iw dev 2>/dev/null | awk '/Interface/ {print $2}'))
    for cand in "${iw_candidates[@]}"; do
      if ip link show "$cand" up &>/dev/null; then
        candidates+=("$cand")
      fi
    done
  fi

  # Filter to those with an IPv4 address and (optionally) WiFi driver
  for cand in "${candidates[@]}"; do
    local cidr
    cidr=$(fct_get_iface_cidr "$cand" 2>/dev/null || true)
    if [[ -n "$cidr" ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo "================================="
  echo " Jetson WiFi Subnet Check"
  echo "================================="
  echo ""

  # 1. Determine host WiFi interface
  if [[ -z "$HOST_IFACE" ]]; then
    echo "--- Detecting host WiFi interface..."
    if ! HOST_IFACE=$(fct_detect_host_wifi_iface); then
      echo "ERROR: No UP WiFi interface with an IP found on host." >&2
      echo "       Specify one with --host-iface." >&2
      exit 1
    fi
    echo "  Detected: $HOST_IFACE"
  fi

  # 2. Get host WiFi CIDR
  HOST_CIDR=$(fct_get_iface_cidr "$HOST_IFACE") || {
    echo "ERROR: Cannot get IPv4 address on interface: $HOST_IFACE" >&2
    exit 1
  }
  HOST_NET=$(fct_calc_network "$HOST_CIDR")
  echo "  Host   WiFi:  $HOST_IFACE     $HOST_CIDR  (network: $HOST_NET)"
  echo ""

  # 3. SSH to Jetson and get wlP1p1s0 CIDR
  echo "--- Connecting to Jetson via SSH..."
  fn_nv_ensure_ssh
  fn_nv_load_env

  if ! fn_nv_check_ssh; then
    echo "ERROR: Cannot reach Jetson at ${SSH_TARGET}." >&2
    echo "       Verify USB bridge (l4tbr0) and SSH setup." >&2
    exit 1
  fi
  echo "  Connected: ${SSH_TARGET}"

  JETSON_CIDR=$(fn_nv_run_remote_bash "ip -4 -o addr show ${JETSON_IFACE} 2>/dev/null | awk '{print \$4}' | head -1" 2>/dev/null || true)
  JETSON_CIDR=$(echo "$JETSON_CIDR" | tr -d '[:space:]')

  if [[ -z "$JETSON_CIDR" ]]; then
    echo "ERROR: Cannot get IPv4 address for $JETSON_IFACE on Jetson." >&2
    echo "       Is the Jetson WiFi connected?" >&2
    exit 1
  fi
  JETSON_NET=$(fct_calc_network "$JETSON_CIDR")
  echo "  Jetson WiFi:  $JETSON_IFACE  $JETSON_CIDR  (network: $JETSON_NET)"
  echo ""

  # 4. Compare subnets
  echo "--- Subnet comparison ---"
  if [[ "$HOST_NET" == "$JETSON_NET" ]]; then
    echo "Result: PASS — both on $HOST_NET"
    echo ""
    exit 0
  else
    echo "Result: FAIL — subnets do not match"
    echo "  Host:   $HOST_NET"
    echo "  Jetson: $JETSON_NET"
    echo ""
    exit 1
  fi
}

main "$@"
