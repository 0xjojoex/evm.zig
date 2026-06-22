#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-fixtures.sh

Downloads generated EEST JSON fixtures into .eest/, which is gitignored.

Environment overrides:
  EEST_REPO       default: ethereum/execution-spec-tests
  EEST_VERSION    default: v5.4.0
  EEST_ARTIFACT   default: fixtures_stable.tar.gz
  EEST_DEST       default: .eest/fixtures/$EEST_VERSION
  EEST_CACHE      default: .eest/cache

Example:
  scripts/fetch-eest-fixtures.sh
  zig build eest -- .eest/fixtures/v5.4.0/fixtures/state_tests/path/to/test.json
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
dest="${EEST_DEST:-.eest/fixtures/${version}}"
cache="${EEST_CACHE:-.eest/cache}"
url="https://github.com/${repo}/releases/download/${version}/${artifact}"
archive="${cache}/${version}-${artifact}"

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
tar -xzf "${archive}" -C "${dest}"

printf 'Done. Try:\n'
printf '  zig build eest -- %s/fixtures/state_tests/<path>.json\n' "${dest}"
