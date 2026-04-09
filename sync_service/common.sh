#!/usr/bin/env bash

_NV_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NV_ENV_FILE="${NV_ENV_FILE:-${_NV_COMMON_DIR}/sync_env}"
_NV_ENV_LOADED=0
_NV_SSH_INITIALIZED=0

# Mirror configuration (override via env if needed)
APT_MIRROR="${APT_MIRROR:-mirrors.ustc.edu.cn}"
DOCKER_APT_MIRROR="${DOCKER_APT_MIRROR:-mirrors.ustc.edu.cn}"

fn_nv_log_info() {
  if [[ "${NV_LOG_LEVEL:-info}" == "silent" ]]; then
    return 0
  fi
  printf '[nv][info] %s\n' "$*"
}

fn_nv_log_warn() {
  if [[ "${NV_LOG_LEVEL:-info}" == "silent" ]]; then
    return 0
  fi
  printf '[nv][warn] %s\n' "$*" >&2
}

fn_nv_log_error() {
  printf '[nv][error] %s\n' "$*" >&2
}

fn_nv_load_env() {
  if [[ "${_NV_ENV_LOADED}" -eq 1 ]]; then
    return 0
  fi

  if [[ -f "${_NV_ENV_FILE}" ]]; then
    fn_nv_log_info "loading config from ${_NV_ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "${_NV_ENV_FILE}"
    set +a
  else
    fn_nv_log_error "config file not found: ${_NV_ENV_FILE}; create it and set the required values there"
    return 1
  fi

  local required_vars=(
    DEVICE_IP
    DEVICE_USER
    DEVICE_PASSWD
    SSH_KEY
    HOST_SOURCE_FOLDER
    DEVICE_TARGET_FOLDER
    HOST_IP
    HOST_PROXY_PORT
  )
  local var_name

  for var_name in "${required_vars[@]}"; do
    if [[ ! -v "${var_name}" ]]; then
      fn_nv_log_error "required env var missing: ${var_name}; set it in ${_NV_ENV_FILE}"
      return 1
    fi
  done

  _NV_ENV_LOADED=1
  fn_nv_log_info "config ready: DEVICE_USER=${DEVICE_USER}, DEVICE_IP=${DEVICE_IP}"
}

fn_nv_reset_ssh() {
  _NV_SSH_INITIALIZED=0
  unset SSH_TARGET SSH_OPTS SSH_CMD SCP_CMD PUBKEY_PATH || true
}

fn_nv_ensure_ssh() {
  local extra_opts=()

  fn_nv_load_env

  if [[ "${_NV_SSH_INITIALIZED}" -eq 1 ]]; then
    return 0
  fi

  if declare -p NV_SSH_EXTRA_OPTS >/dev/null 2>&1; then
    extra_opts=("${NV_SSH_EXTRA_OPTS[@]}")
  fi

  SSH_OPTS=("${extra_opts[@]}")
  if [[ -n "${SSH_KEY}" && -f "${SSH_KEY}" ]]; then
    SSH_OPTS+=(-i "${SSH_KEY}")
  fi

  SSH_TARGET="${DEVICE_USER}@${DEVICE_IP}"
  SSH_CMD=(ssh "${SSH_OPTS[@]}" "${SSH_TARGET}")
  SCP_CMD=(scp "${SSH_OPTS[@]}")
  PUBKEY_PATH="${SSH_KEY}.pub"
  _NV_SSH_INITIALIZED=1
  fn_nv_log_info "ssh initialized for ${SSH_TARGET}"
}

fn_nv_check_ssh() {
  fn_nv_ensure_ssh
  fn_nv_log_info "checking ssh connectivity to ${SSH_TARGET}"
  "${SSH_CMD[@]}" "echo ok" >/dev/null 2>&1
}

fn_nv_run_remote_bash() {
  local command="$1"
  local remote_cmd

  fn_nv_ensure_ssh

  remote_cmd="bash -l -c $(printf '%q' "$command")"
  "${SSH_CMD[@]}" "${remote_cmd}"
}

fn_nv_run_remote_bash_script() {
  local script
  script="$(cat)"
  fn_nv_run_remote_bash "$script"
}

fn_nv_run_remote_sudo_bash() {
  local command="$1"
  local remote_cmd

  fn_nv_ensure_ssh
  fn_nv_load_env

  if [[ -n "${DEVICE_PASSWD}" ]]; then
    remote_cmd="printf '%s\\n' $(printf '%q' "${DEVICE_PASSWD}") | sudo -S -p '' bash -l -c $(printf '%q' "$command")"
  else
    remote_cmd="sudo -n bash -l -c $(printf '%q' "$command")"
  fi

  "${SSH_CMD[@]}" "${remote_cmd}"
}

fn_nv_run_remote_sudo_bash_script() {
  local script
  script="$(cat)"
  fn_nv_run_remote_sudo_bash "$script"
}

fn_nv_setup_apt_sources() {
  fn_nv_load_env
  fn_nv_ensure_ssh
  fn_nv_log_info "setting up apt sources on ${SSH_TARGET}"
  fn_nv_run_remote_sudo_bash "find /etc/apt -type f \\( -name '*.list' -o -name '*.sources' \\) -exec sed -i 's|http://ports.ubuntu.com/ubuntu-ports|http://${APT_MIRROR}/ubuntu-ports|g' {} + && find /etc/apt -type f \\( -name '*.list' -o -name '*.sources' \\) -exec sed -i 's|https://mirrors.aliyun.com/ubuntu-ports|http://${APT_MIRROR}/ubuntu-ports|g' {} + && find /etc/apt -type f \\( -name '*.list' -o -name '*.sources' \\) -exec sed -i 's|https://download.docker.com/linux/ubuntu|http://${DOCKER_APT_MIRROR}/docker-ce/linux/ubuntu|g' {} + && printf '%s\n' 'Acquire::ForceIPv4 \"true\";' > /etc/apt/apt.conf.d/99force-ipv4 && printf 'Acquire::http::Proxy \"http://${HOST_IP}:${HOST_PROXY_PORT}/\";\nAcquire::https::Proxy \"http://${HOST_IP}:${HOST_PROXY_PORT}/\";\n' > /etc/apt/apt.conf.d/99proxy && apt update"
}
