#!/usr/bin/env bash
#
# Synchronously push jetson-suffix Docker images to the Jetson device.
# Integrity check: local sha256 -> scp -> remote sha256 verify -> docker load -> inspect digest match
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

IMAGE_ENV_FILE="${SCRIPT_DIR}/sync-image.env"
_STAGING_DIR=""
_REMOTE_STAGING_DIR=""
_SSH_COMPRESSION=false
_FAIL_FAST=true
_IMAGES=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2; }
log_step() { printf '%b[STEP]%b %s\n' "$BLUE" "$NC" "$1"; }

fn_image_load_env() {
  if [[ -f "${IMAGE_ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${IMAGE_ENV_FILE}"
    set +a
  else
    log_error "Image config not found: ${IMAGE_ENV_FILE}"
    return 1
  fi

  : "${STAGING_DIR:=/tmp/vtol-image-staging}"
  : "${REMOTE_STAGING_DIR:=/tmp/vtol-image-staging}"
  : "${SSH_COMPRESSION:=false}"
  : "${FAIL_FAST:=true}"

  if [[ -z "${SYNC_IMAGES:-}" ]]; then
    log_error "SYNC_IMAGES is empty in ${IMAGE_ENV_FILE}"
    return 1
  fi

  read -ra _IMAGES <<< "${SYNC_IMAGES}"
  _STAGING_DIR="${STAGING_DIR}"
  _REMOTE_STAGING_DIR="${REMOTE_STAGING_DIR}"
  _SSH_COMPRESSION="${SSH_COMPRESSION}"
  _FAIL_FAST="${FAIL_FAST}"
}

fn_image_to_filename() {
  local image="$1"
  local name
  name="${image//\//_}"
  name="${name//:/_}"
  printf '%s' "${name}"
}

fn_image_already_in_sync() {
  local image="$1"
  local local_id remote_id

  local_id=$(docker inspect --format='{{.Id}}' "${image}" 2>/dev/null) || {
    log_error "Cannot inspect local image: ${image}"
    return 1
  }

  fn_nv_ensure_ssh
  remote_id=$("${SSH_CMD[@]}" "docker inspect --format='{{.Id}}' ${image}" 2>/dev/null) || {
    return 1
  }

  if [[ "${local_id}" == "${remote_id}" ]]; then
    return 0
  fi
  return 1
}

fn_sync_single_image() {
  local image="$1"
  local fname
  fname=$(fn_image_to_filename "${image}")
  local tar_file="${_STAGING_DIR}/${fname}.tar"
  local sha_file="${_STAGING_DIR}/${fname}.sha256"
  local remote_tar="${_REMOTE_STAGING_DIR}/${fname}.tar"
  local remote_sha="${_REMOTE_STAGING_DIR}/${fname}.sha256"

  log_step "Processing image: ${image}"

  if fn_image_already_in_sync "${image}"; then
    log_info "Image already in sync, skipping: ${image}"
    return 0
  fi

  mkdir -p "${_STAGING_DIR}"

  log_step "Saving image to tar: ${tar_file}"
  docker save "${image}" -o "${tar_file}"

  local tar_size
  tar_size=$(du -h "${tar_file}" | cut -f1)
  log_info "Tar size: ${tar_size}"

  log_step "Computing sha256 checksum..."
  (cd "${_STAGING_DIR}" && sha256sum "$(basename "${tar_file}")" > "$(basename "${sha_file}")")

  fn_nv_ensure_ssh
  "${SSH_CMD[@]}" "mkdir -p ${_REMOTE_STAGING_DIR}"

  local scp_opts=()
  if [[ "${_SSH_COMPRESSION}" == "true" ]]; then
    scp_opts+=(-C)
  fi

  log_step "Transferring tar to ${DEVICE_USER}@${DEVICE_IP}..."
  scp "${scp_opts[@]}" -i "${SSH_KEY}" "${tar_file}" "${sha_file}" \
    "${DEVICE_USER}@${DEVICE_IP}:${_REMOTE_STAGING_DIR}/"

  log_step "Verifying checksum on remote..."
  local verify_exit=0
  "${SSH_CMD[@]}" "cd ${_REMOTE_STAGING_DIR} && sha256sum -c $(basename "${sha_file}")" \
    || verify_exit=$?

  if [[ $verify_exit -ne 0 ]]; then
    log_error "SHA256 checksum mismatch for ${image}!"
    log_error "Remote tar kept at ${_REMOTE_STAGING_DIR}/${fname}.tar for diagnosis"
    return 1
  fi
  log_info "Checksum verified OK"

  log_step "Loading image on remote..."
  "${SSH_CMD[@]}" "docker load -i ${remote_tar}" || {
    log_error "docker load failed for ${image}"
    return 1
  }

  log_step "Verifying image digest on remote..."
  local local_id remote_id
  local_id=$(docker inspect --format='{{.Id}}' "${image}" 2>/dev/null)
  remote_id=$("${SSH_CMD[@]}" "docker inspect --format='{{.Id}}' ${image}" 2>/dev/null) || {
    log_error "Cannot inspect remote image after load"
    return 1
  }

  if [[ "${local_id}" != "${remote_id}" ]]; then
    log_error "Image digest mismatch after load!"
    log_error "  Local:  ${local_id}"
    log_error "  Remote: ${remote_id}"
    return 1
  fi
  log_info "Image digest match: ${local_id}"

  log_step "Cleaning up tar files..."
  rm -f "${tar_file}" "${sha_file}"
  "${SSH_CMD[@]}" "rm -f ${remote_tar} ${remote_sha}" || true

  log_info "Image synced successfully: ${image}"
  return 0
}

fn_sync_all() {
  fn_nv_load_env
  fn_image_load_env

  local total=${#_IMAGES[@]}
  local success=0
  local failed=0

  log_info "Starting image sync: ${total} image(s)"
  log_info "Target: ${DEVICE_USER}@${DEVICE_IP}"
  echo ""

  for image in "${_IMAGES[@]}"; do
    echo "------------------------------------------"
    if fn_sync_single_image "${image}"; then
      ((success++)) || true
    else
      ((failed++)) || true
      if [[ "${_FAIL_FAST}" == "true" ]]; then
        log_error "FAIL_FAST enabled, aborting remaining images"
        break
      fi
    fi
    echo ""
  done

  echo "=========================================="
  printf '%bSync Summary%b\n' "$BLUE" "$NC"
  echo "=========================================="
  echo "  Total:   ${total}"
  printf '  %bSuccess: %d%b\n' "$GREEN" "$success" "$NC"
  if [[ $failed -gt 0 ]]; then
    printf '  %bFailed:  %d%b\n' "$RED" "$failed" "$NC"
  fi
  echo "=========================================="

  if [[ $failed -gt 0 ]]; then
    return 1
  fi
  return 0
}

fn_ensure_images() {
  fn_nv_load_env
  fn_image_load_env

  log_info "Checking image sync status..."
  local out_of_sync=()

  for image in "${_IMAGES[@]}"; do
    if ! fn_image_already_in_sync "${image}"; then
      out_of_sync+=("${image}")
    else
      log_info "OK: ${image}"
    fi
  done

  if [[ ${#out_of_sync[@]} -eq 0 ]]; then
    log_info "All images in sync"
    return 0
  fi

  log_warn "Out of sync: ${out_of_sync[*]}"
  log_info "Starting sync..."
  fn_sync_all
}

fn_show_status() {
  fn_nv_load_env
  fn_image_load_env
  fn_nv_ensure_ssh

  echo "Image sync status:"
  echo ""

  for image in "${_IMAGES[@]}"; do
    local local_id
    local_id=$(docker inspect --format='{{.Id}}' "${image}" 2>/dev/null) || {
      printf '  %bMISSING%b %s (not built locally)\n' "$RED" "$NC" "${image}"
      continue
    }

    local remote_id
    remote_id=$("${SSH_CMD[@]}" "docker inspect --format='{{.Id}}' ${image}" 2>/dev/null) || {
      printf '  %bMISSING%b %s (not on device)\n' "$YELLOW" "$NC" "${image}"
      continue
    }

    if [[ "${local_id}" == "${remote_id}" ]]; then
      printf '  %bSYNCED%b %s\n' "$GREEN" "$NC" "${image}"
    else
      printf '  %bSTALE%b  %s\n' "$YELLOW" "$NC" "${image}"
      printf '           local:  %s\n' "${local_id:0:20}"
      printf '           remote: %s\n' "${remote_id:0:20}"
    fi
  done
}

show_help() {
  cat << EOF
Usage: $(basename "$0") <command> [OPTIONS]

Synchronously push Docker images to the Jetson device with integrity checks.

Commands:
  sync-all    Sync all images listed in sync-image.env
  ensure      Sync only images that are out of date (idempotent)
  status      Show sync status for all images

Options:
  -h, --help      Show this help message
  --image IMG     Override SYNC_IMAGES with a single image
EOF
}

main() {
  local command=""
  local override_image=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      --image)
        override_image="$2"
        shift 2
        ;;
      -*)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
      *)
        if [[ -z "${command}" ]]; then
          command="$1"
          shift
        else
          shift
        fi
        ;;
    esac
  done

  if [[ -n "${override_image}" ]]; then
    export SYNC_IMAGES="${override_image}"
  fi

  case "${command}" in
    sync-all)
      fn_sync_all
      ;;
    ensure)
      fn_ensure_images
      ;;
    status)
      fn_show_status
      ;;
    "")
      show_help
      exit 1
      ;;
    *)
      log_error "Unknown command: ${command}"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
