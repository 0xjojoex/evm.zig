#!/usr/bin/env bash

consensus_lock_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONSENSUS_PROJECT_ROOT="$(cd -- "${consensus_lock_script_dir}/../.." && pwd)"
CONSENSUS_LOCK_PATH="${CONSENSUS_LOCK_PATH:-${CONSENSUS_PROJECT_ROOT}/eest/consensus.lock}"

consensus_lock_value() {
  local key="$1"
  local value
  value="$(awk -F= -v key="${key}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      lhs=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      if (lhs == key) {
        sub(/^[^=]*=/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print
        exit
      }
    }
  ' "${CONSENSUS_LOCK_PATH}")"
  if [[ -z "${value}" ]]; then
    printf 'error: missing %s in %s\n' "${key}" "${CONSENSUS_LOCK_PATH}" >&2
    return 1
  fi
  printf '%s\n' "${value}"
}

consensus_release_url() {
  local repo="$1"
  local release="$2"
  local artifact="$3"
  printf 'https://github.com/%s/releases/download/%s/%s\n' \
    "${repo}" "${release//@/%40}" "${artifact}"
}
