#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

fn_nv_load_env
fn_nv_ensure_ssh

if [[ ! -f "${PUBKEY_PATH}" ]]; then
  echo "Error: Public key not found: ${PUBKEY_PATH}"
  echo ""
  echo "Please create an SSH key pair first:"
  echo "  ssh-keygen -t ed25519 -C "your_email@example.com""
  exit 1
fi

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$DEVICE_IP" 2>/dev/null || true

if command -v ssh-copy-id >/dev/null 2>&1; then
  ssh-copy-id -i "${PUBKEY_PATH}" "${SSH_TARGET}"
else
  echo "ssh-copy-id not found, using manual method..."
  PUBKEY_B64=$(base64 -w0 "${PUBKEY_PATH}")
  "${SSH_CMD[@]}" "PUBKEY_B64='${PUBKEY_B64}'" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

PUBKEY_CONTENT=$(echo "$PUBKEY_B64" | base64 -d)
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

if [[ -e "$SSH_DIR" && ! -d "$SSH_DIR" ]]; then
  echo "Error: $SSH_DIR exists but is not a directory" >&2
  exit 1
fi

if [[ ! -d "$SSH_DIR" ]]; then
  mkdir -p "$SSH_DIR"
fi
chmod 700 "$SSH_DIR"

if [[ -e "$AUTH_KEYS" && ! -f "$AUTH_KEYS" ]]; then
  echo "Error: $AUTH_KEYS exists but is not a regular file" >&2
  exit 1
fi

touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if grep -qxF "$PUBKEY_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
  echo "Key already exists in authorized_keys"
else
  printf '%s
' "$PUBKEY_CONTENT" >> "$AUTH_KEYS"
  echo "Key added to authorized_keys"
fi
REMOTE_SCRIPT
fi

echo "Public key copied successfully to ${SSH_TARGET}"
