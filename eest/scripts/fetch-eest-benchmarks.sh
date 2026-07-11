#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-benchmarks.sh

Downloads generated EEST benchmark JSON fixtures into ../.eest/, which is gitignored.

Environment overrides:
  EEST_REPO               default: ethereum/execution-specs
  EEST_BENCHMARK_VERSION  default: tests-benchmark@v0.0.9
  EEST_BENCHMARK_ARTIFACT default: fixtures_benchmark.tar.gz
  EEST_BENCHMARK_DEST     default: ../.eest/benchmarks/tests-benchmark-v0.0.9
  EEST_CACHE              default: ../.eest/cache

Example:
  scripts/fetch-eest-benchmarks.sh
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

repo="${EEST_REPO:-ethereum/execution-specs}"
version="${EEST_BENCHMARK_VERSION:-tests-benchmark@v0.0.9}"
artifact="${EEST_BENCHMARK_ARTIFACT:-fixtures_benchmark.tar.gz}"
version_slug="${version//@/-}"
url_version="${version//@/%40}"
dest="${EEST_BENCHMARK_DEST:-../.eest/benchmarks/${version_slug}}"
cache="${EEST_CACHE:-../.eest/cache}"
url="https://github.com/${repo}/releases/download/${url_version}/${artifact}"
archive="${cache}/${version_slug}-${artifact}"

cleanup_tmp() {
  if [[ -n "${tmp:-}" && -f "${tmp}" ]]; then
    if command -v trash >/dev/null 2>&1; then
      trash "${tmp}"
    else
      rm -f "${tmp}"
    fi
  fi
}
trap cleanup_tmp EXIT

mkdir -p "${cache}" "${dest}"

if [[ ! -f "${archive}" ]]; then
  tmp="${archive}.tmp"
  printf 'Downloading %s\n' "${url}"
  curl --fail --location --show-error --progress-bar --output "${tmp}" "${url}"
  mv "${tmp}" "${archive}"
  tmp=""
else
  printf 'Using cached %s\n' "${archive}"
fi

printf 'Extracting to %s\n' "${dest}"
tar -xzf "${archive}" -C "${dest}"

printf 'Done. Benchmark fixtures are cached at %s for future adapter work.\n' "${dest}"
printf 'No active EEST benchmark runner consumes them today; use bench/ VM-loop reports for routine comparisons.\n'
