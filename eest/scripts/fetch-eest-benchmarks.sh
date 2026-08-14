#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/eest-lock.sh"

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-benchmarks.sh

Downloads generated EEST benchmark JSON fixtures into ../.eest/, which is gitignored.

Environment overrides:
  EEST_BENCHMARK_REPO      repository override
  EEST_BENCHMARK_RELEASE   release override
  EEST_BENCHMARK_ARTIFACT  artifact override
  EEST_BENCHMARK_URL       download URL override
  EEST_BENCHMARK_SHA256    checksum override
  EEST_BENCHMARK_DEST      extraction destination override
  EEST_CACHE               shared archive cache override

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

repo="${EEST_BENCHMARK_REPO:-$(eest_lock_value benchmark_repo)}"
release="${EEST_BENCHMARK_RELEASE:-$(eest_lock_value benchmark_release)}"
artifact="${EEST_BENCHMARK_ARTIFACT:-$(eest_lock_value benchmark_artifact)}"
release_slug="$(eest_release_slug "${release}")"
dest="${EEST_BENCHMARK_DEST:-$(eest_release_path benchmark "${release}")}"
cache="${EEST_CACHE:-${EEST_LOCK_REPO_ROOT}/.eest/cache}"
url="${EEST_BENCHMARK_URL:-$(eest_release_url "${repo}" "${release}" "${artifact}")}"
archive="${cache}/${release_slug}-${artifact}"
if [[ -n "${EEST_BENCHMARK_SHA256:-}" ]]; then
  sha256="${EEST_BENCHMARK_SHA256}"
elif [[ -z "${EEST_BENCHMARK_REPO:-}" && -z "${EEST_BENCHMARK_RELEASE:-}" && -z "${EEST_BENCHMARK_ARTIFACT:-}" && -z "${EEST_BENCHMARK_URL:-}" ]]; then
  sha256="$(eest_lock_value benchmark_sha256)"
else
  sha256=""
fi

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

verify_archive() {
  local path="$1"
  local actual_sha256
  if [[ -z "${sha256}" ]]; then
    printf 'No SHA-256 configured; skipping archive verification\n'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "${path}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_sha256="$(shasum -a 256 "${path}" | awk '{print $1}')"
  else
    printf 'error: sha256sum or shasum is required\n' >&2
    return 1
  fi
  if [[ "${actual_sha256}" != "${sha256}" ]]; then
    printf 'fixture archive checksum mismatch\n  expected: %s\n  actual:   %s\n' "${sha256}" "${actual_sha256}" >&2
    return 1
  fi
  printf 'Verified SHA-256 %s\n' "${sha256}"
}

if [[ ! -f "${archive}" ]]; then
  tmp="${archive}.tmp"
  printf 'Downloading %s\n' "${url}"
  curl --fail --location --show-error --progress-bar --output "${tmp}" "${url}"
  verify_archive "${tmp}"
  mv "${tmp}" "${archive}"
  tmp=""
else
  printf 'Using cached %s\n' "${archive}"
  verify_archive "${archive}"
fi

printf 'Extracting to %s\n' "${dest}"
tar -xzf "${archive}" -C "${dest}"

printf 'Done. Benchmark fixtures are cached at %s for future adapter work.\n' "${dest}"
printf 'No active EEST benchmark runner consumes them today; use bench/ VM-loop reports for routine comparisons.\n'
