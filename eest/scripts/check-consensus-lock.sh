#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/consensus-lock.sh"

required_keys=(
  repo release
  general_artifact general_sha256
  mainnet_artifact mainnet_sha256
  minimal_artifact minimal_sha256
)
for key in "${required_keys[@]}"; do
  consensus_lock_value "${key}" >/dev/null
done

release="$(consensus_lock_value release)"
if ! grep -Fq "pub const source_release = \"${release}\";" \
  "${CONSENSUS_PROJECT_ROOT}/eest/src/ssz_static/index.zig"; then
  printf 'error: generated SSZ provenance does not match consensus.lock\n' >&2
  exit 1
fi

printf 'consensus fixture lock is internally consistent\n'
