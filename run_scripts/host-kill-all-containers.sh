#!/usr/bin/env bash
set -Eeuo pipefail

fct_print_usage() {
  printf 'Usage: %s\n' "$0"
  printf 'Force remove all Docker containers from docker ps -a.\n'
}

fct_main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    fct_print_usage
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    printf 'ERROR: docker is not installed.\n' >&2
    return 1
  fi

  mapfile -t container_ids < <(docker ps -aq)

  if [[ ${#container_ids[@]} -eq 0 ]]; then
    printf 'No containers found.\n'
    return 0
  fi

  printf 'Removing %d container(s)...\n' "${#container_ids[@]}"
  docker rm -f "${container_ids[@]}"
  printf 'All containers were removed.\n'
}

fct_main "$@"
