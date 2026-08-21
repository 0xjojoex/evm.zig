#!/usr/bin/env bash

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  eest_lock_source="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  eest_lock_source="${(%):-%x}"
else
  printf 'error: cannot resolve eest-lock.sh location\n' >&2
  return 1
fi
eest_lock_script_dir="$(cd -- "$(dirname -- "${eest_lock_source}")" && pwd)"
EEST_LOCK_REPO_ROOT="$(cd -- "${eest_lock_script_dir}/../.." && pwd)"
EEST_LOCK_PATH="${EEST_LOCK_PATH:-${EEST_LOCK_REPO_ROOT}/eest.lock}"

eest_lock_value() {
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
  ' "${EEST_LOCK_PATH}")"
  if [[ -z "${value}" ]]; then
    printf 'error: missing %s in %s\n' "${key}" "${EEST_LOCK_PATH}" >&2
    return 1
  fi
  printf '%s\n' "${value}"
}

eest_release_slug() {
  local release="$1"
  printf '%s\n' "${release//@/-}"
}

eest_release_url() {
  local repo="$1"
  local release="$2"
  local artifact="$3"
  printf 'https://github.com/%s/releases/download/%s/%s\n' \
    "${repo}" "${release//@/%40}" "${artifact}"
}

eest_release_relative_dest() {
  local track="$1"
  local release="$2"
  local slug
  slug="$(eest_release_slug "${release}")"
  case "${track}" in
    state|zkevm) printf '.eest/fixtures/%s\n' "${slug}" ;;
    benchmark|zkevm_benchmark) printf '.eest/benchmarks/%s\n' "${slug}" ;;
    consensus) printf '.eest/consensus/%s\n' "${slug}" ;;
    *)
      printf 'error: unknown fixture track: %s\n' "${track}" >&2
      return 1
      ;;
  esac
}

eest_release_path() {
  local relative
  relative="$(eest_release_relative_dest "$1" "$2")"
  printf '%s/%s\n' "${EEST_LOCK_REPO_ROOT}" "${relative}"
}

eest_lock_path() {
  local value
  value="$(eest_lock_value "$1")"
  if [[ "${value}" = /* ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s/%s\n' "${EEST_LOCK_REPO_ROOT}" "${value}"
  fi
}
