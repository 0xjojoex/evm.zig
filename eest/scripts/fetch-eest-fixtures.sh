#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-fixtures.sh

Downloads generated EEST JSON fixtures into ../.eest/, which is gitignored.

Environment overrides:
  EEST_REPO       default: ethereum/execution-spec-tests
  EEST_VERSION    default: v5.4.0
  EEST_ARTIFACT   default: fixtures_stable.tar.gz
  EEST_DEST       default: ../.eest/fixtures/${EEST_VERSION//@/-}
  EEST_CACHE      default: ../.eest/cache
  EEST_PRUNE_OUT_OF_SCOPE
                   default: 1; excludes client/engine fixtures from extraction

Example:
  scripts/fetch-eest-fixtures.sh
  zig build eest -- ../.eest/fixtures/v5.4.0/fixtures/state_tests/path/to/test.json

Latest moving test-release fixtures are published on ethereum/execution-specs
under tests-* tags. The default remains the latest supported stable Osaka
corpus; override EEST_REPO/EEST_VERSION/EEST_ARTIFACT for newer fork work.
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

repo="${EEST_REPO:-ethereum/execution-spec-tests}"
version="${EEST_VERSION:-v5.4.0}"
artifact="${EEST_ARTIFACT:-fixtures_stable.tar.gz}"
version_slug="${version//@/-}"
url_version="${version//@/%40}"
dest="${EEST_DEST:-../.eest/fixtures/${version_slug}}"
cache="${EEST_CACHE:-../.eest/cache}"
prune_out_of_scope="${EEST_PRUNE_OUT_OF_SCOPE:-1}"
url="https://github.com/${repo}/releases/download/${url_version}/${artifact}"
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
