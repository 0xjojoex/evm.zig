#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/eest-lock.sh"

required_keys=(
  state_release
  benchmark_repo benchmark_release benchmark_artifact benchmark_sha256
  zkevm_repo zkevm_release zkevm_artifact zkevm_sha256
  zkevm_mutations_manifest zkevm_steps_manifest
  consensus_repo consensus_release
  consensus_general_artifact consensus_general_sha256
  consensus_mainnet_artifact consensus_mainnet_sha256
  consensus_minimal_artifact consensus_minimal_sha256
)
for key in "${required_keys[@]}"; do
  eest_lock_value "${key}" >/dev/null
done

legacy_keys=(
  repo version artifact url sha256 dest
  benchmark_version benchmark_url benchmark_dest
  zkevm_version zkevm_url zkevm_dest
  consensus_version consensus_general_url consensus_mainnet_url
  consensus_minimal_url consensus_dest
)
for key in "${legacy_keys[@]}"; do
  if awk -F= -v key="${key}" '$1 == key { found=1 } END { exit !found }' "${EEST_LOCK_PATH}"; then
    printf 'error: legacy fixture lock key remains: %s\n' "${key}" >&2
    exit 1
  fi
done

for key in zkevm_mutations_manifest zkevm_steps_manifest; do
  path="$(eest_lock_path "${key}")"
  if [[ ! -f "${path}" ]]; then
    printf 'error: %s does not exist: %s\n' "${key}" "${path}" >&2
    exit 1
  fi
done

reject_pattern() {
  local description="$1"
  local pattern="$2"
  local matches
  matches="$(git -C "${EEST_LOCK_REPO_ROOT}" grep -n -E -- "${pattern}" -- . \
    ':!eest.lock' \
    ':!eest/fixtures/**' \
    ':!eest/src/ssz_static/index.zig' || true)"
  if [[ -n "${matches}" ]]; then
    printf 'error: copied %s outside its allowed owners:\n%s\n' "${description}" "${matches}" >&2
    exit 1
  fi
}

reject_pattern "execution-spec release" \
  'tests-[[:alnum:]_-]+@v[[:digit:]][[:alnum:]._-]*|tests-[[:alnum:]_-]+-v[[:digit:]][[:alnum:]._-]*'
reject_pattern "consensus-spec release" \
  '\.eest/consensus/v[[:digit:]][[:alnum:]._-]*|consensus-specs v[[:digit:]][[:alnum:]._-]*|--branch v[[:digit:]][[:alnum:]._-]*'

for track in state benchmark zkevm consensus; do
  release="$(eest_lock_value "${track}_release")"
  release_slug="$(eest_release_slug "${release}")"
  for identity in "${release}" "${release_slug}"; do
    matches="$(git -C "${EEST_LOCK_REPO_ROOT}" grep -n -F -- "${identity}" -- . \
      ':!eest.lock' \
      ':!eest/fixtures/**' \
      ':!eest/src/ssz_static/index.zig' || true)"
    if [[ -n "${matches}" ]]; then
      printf 'error: copied %s release outside its allowed owners:\n%s\n' "${track}" "${matches}" >&2
      exit 1
    fi
    [[ "${identity}" != "${release_slug}" ]] || break
  done
done

consensus_release="$(eest_lock_value consensus_release)"
if ! grep -Fq "pub const source_release = \"${consensus_release}\";" \
  "${EEST_LOCK_REPO_ROOT}/eest/src/ssz_static/index.zig"; then
  printf 'error: generated SSZ provenance does not match consensus_release\n' >&2
  exit 1
fi

printf 'fixture lock is authoritative and internally consistent\n'
