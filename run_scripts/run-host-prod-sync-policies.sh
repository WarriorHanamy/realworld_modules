#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# run-host-prod-sync-policies.sh — Host-side policy sync for Jetson runtime
#
# Runs on the host machine.
# Copies policy files from $HOME/server/policies to the Jetson path
# /home/nv/server/policies using the shared remote execution helpers.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../sync_service/common.sh"
HOST_POLICIES_DIR="${HOME}/server/policies"
JETSON_POLICIES_DIR="/home/nv/server/policies"

if [[ ! -f "${COMMON_SH}" ]]; then
  echo "ERROR: Remote execution helpers not found: ${COMMON_SH}"
  exit 1
fi

# shellcheck source=/dev/null
source "${COMMON_SH}"
fn_nv_ensure_ssh

if [[ ! -d "${HOST_POLICIES_DIR}" ]]; then
  echo "ERROR: Host policies directory not found: ${HOST_POLICIES_DIR}"
  exit 1
fi

if [[ -z "$(ls -A "${HOST_POLICIES_DIR}" 2>/dev/null)" ]]; then
  echo "WARNING: Host policies directory is empty: ${HOST_POLICIES_DIR}"
fi

echo ">>> Creating target directory on Jetson..."
if ! fn_nv_run_remote_bash "mkdir -p ${JETSON_POLICIES_DIR}"; then
  echo "ERROR: Failed to create remote directory ${JETSON_POLICIES_DIR}"
  exit 1
fi

echo ">>> Syncing policies from host to Jetson..."
echo "  Source: ${HOST_POLICIES_DIR}"
echo "  Target: ${SSH_TARGET}:${JETSON_POLICIES_DIR}"

if ! "${SCP_CMD[@]}" -r "${HOST_POLICIES_DIR}/." "${SSH_TARGET}:${JETSON_POLICIES_DIR}/"; then
  echo "ERROR: Failed to sync policies to Jetson"
  exit 1
fi

echo ">>> Policies synced successfully"
echo ">>> Verifying remote files..."
fn_nv_run_remote_bash "ls -la ${JETSON_POLICIES_DIR}" || true
