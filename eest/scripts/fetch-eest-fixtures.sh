#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-fixtures.sh

Downloads generated EEST JSON fixtures into ../.eest/, which is gitignored.

Environment overrides:
  EEST_REPO       default: repo from ../eest.lock
  EEST_VERSION    default: version from ../eest.lock
  EEST_ARTIFACT   default: artifact from ../eest.lock
  EEST_URL        default: url from ../eest.lock, or GitHub release URL
  EEST_DEST       default: dest from ../eest.lock
  EEST_CACHE      default: ../.eest/cache
  EEST_PRUNE_OUT_OF_SCOPE
                   default: 1; excludes client/engine fixtures from extraction

Example:
  scripts/fetch-eest-fixtures.sh
  zig build eest -- ../.eest/fixtures/tests-glamsterdam-devnet-v6.1.0/fixtures/state_tests/path/to/test.json

State fixture defaults come from eest.lock. The current lock tracks the
Glamsterdam devnet EEST release for Amsterdam work; override
EEST_REPO/EEST_VERSION/EEST_ARTIFACT/EEST_URL for ad-hoc fixture tracks.
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

lock_path=""
lock_prefix=""
if [[ -f "../eest.lock" ]]; then
  lock_path="../eest.lock"
  lock_prefix=".."
elif [[ -f "eest.lock" ]]; then
  lock_path="eest.lock"
fi

lock_value() {
  local key="$1"
  [[ -n "${lock_path}" ]] || return 1
  awk -F= -v key="${key}" '
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
  ' "${lock_path}"
}

lock_path_value() {
  local key="$1"
  local value
  value="$(lock_value "${key}")"
  [[ -n "${value}" ]] || return 1
  if [[ "${value}" = /* || -z "${lock_prefix}" ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s/%s\n' "${lock_prefix}" "${value}"
  fi
}

lock_repo="$(lock_value repo || true)"
lock_version="$(lock_value version || true)"
lock_artifact="$(lock_value artifact || true)"
lock_url="$(lock_value url || true)"

repo="${EEST_REPO:-${lock_repo:-ethereum/execution-specs}}"
version="${EEST_VERSION:-${lock_version:-tests-glamsterdam-devnet@v6.1.0}}"
artifact="${EEST_ARTIFACT:-${lock_artifact:-fixtures_glamsterdam-devnet.tar.gz}}"
version_slug="${version//@/-}"
url_version="${version//@/%40}"
dest="${EEST_DEST:-$(lock_path_value dest || printf '../.eest/fixtures/%s' "${version_slug}")}"
cache="${EEST_CACHE:-../.eest/cache}"
prune_out_of_scope="${EEST_PRUNE_OUT_OF_SCOPE:-1}"
if [[ -n "${EEST_URL:-}" ]]; then
  url="${EEST_URL}"
elif [[ -z "${EEST_REPO:-}" && -z "${EEST_VERSION:-}" && -z "${EEST_ARTIFACT:-}" && -n "${lock_url}" ]]; then
  url="${lock_url}"
else
  url="https://github.com/${repo}/releases/download/${url_version}/${artifact}"
fi
archive="${cache}/${version_slug}-${artifact}"
out_of_scope_tracks=(
  "fixtures/blockchain_tests"
  "fixtures/blockchain_tests_engine"
  "fixtures/blockchain_tests_engine_x"
)

mkdir -p "${cache}" "${dest}"

if [[ ! -f "${archive}" ]]; then
  tmp="${archive}.tmp"
  rm -f "${tmp}"
  printf 'Downloading %s\n' "${url}"
  curl --fail --location --show-error --progress-bar --output "${tmp}" "${url}"
  mv "${tmp}" "${archive}"
else
  printf 'Using cached %s\n' "${archive}"
fi

printf 'Extracting to %s\n' "${dest}"
tar_args=()
if [[ "${prune_out_of_scope}" != "0" ]]; then
  for track in "${out_of_scope_tracks[@]}"; do
    tar_args+=("--exclude=${track}" "--exclude=${track}/*")
  done
fi
tar "${tar_args[@]}" -xzf "${archive}" -C "${dest}"

if [[ "${prune_out_of_scope}" != "0" ]]; then
  printf 'Pruning out-of-scope client/engine fixtures\n'
  for track in "${out_of_scope_tracks[@]}"; do
    rm -rf "${dest}/${track}"
  done
fi

printf 'Done. Try:\n'
printf '  zig build eest -- %s/fixtures/state_tests/<path>.json\n' "${dest}"
