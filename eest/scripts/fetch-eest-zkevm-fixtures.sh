#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-zkevm-fixtures.sh

Downloads EEST zkEVM blockchain fixtures into ../.eest/.

Environment overrides:
  EEST_ZKEVM_REPO      default: zkevm_repo from ../eest.lock
  EEST_ZKEVM_VERSION   default: zkevm_version from ../eest.lock
  EEST_ZKEVM_ARTIFACT  default: zkevm_artifact from ../eest.lock
  EEST_ZKEVM_URL       default: zkevm_url from ../eest.lock, or GitHub release URL
  EEST_ZKEVM_SHA256    default: zkevm_sha256 from ../eest.lock for the locked release
  EEST_ZKEVM_DEST      default: zkevm_dest from ../eest.lock
  EEST_CACHE           default: ../.eest/cache

Example:
  scripts/fetch-eest-zkevm-fixtures.sh
  zig build zkevm -- ../.eest/fixtures/tests-zkevm-v0.6.2/fixtures/blockchain_tests/path/to/test.json
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

repo="${EEST_ZKEVM_REPO:-$(lock_value zkevm_repo || printf 'ethereum/execution-specs')}"
version="${EEST_ZKEVM_VERSION:-$(lock_value zkevm_version || printf 'tests-zkevm@v0.6.2')}"
artifact="${EEST_ZKEVM_ARTIFACT:-$(lock_value zkevm_artifact || printf 'fixtures_zkevm.tar.gz')}"
version_slug="${version//@/-}"
url_version="${version//@/%40}"
dest="${EEST_ZKEVM_DEST:-$(lock_path_value zkevm_dest || printf '../.eest/fixtures/%s' "${version_slug}")}"
cache="${EEST_CACHE:-../.eest/cache}"
archive="${cache}/${version_slug}-${artifact}"

if [[ -n "${EEST_ZKEVM_SHA256:-}" ]]; then
  sha256="${EEST_ZKEVM_SHA256}"
elif [[ -z "${EEST_ZKEVM_REPO:-}" && -z "${EEST_ZKEVM_VERSION:-}" && -z "${EEST_ZKEVM_ARTIFACT:-}" && -z "${EEST_ZKEVM_URL:-}" ]]; then
  sha256="$(lock_value zkevm_sha256 || true)"
else
  sha256=""
fi

if [[ -n "${EEST_ZKEVM_URL:-}" ]]; then
  url="${EEST_ZKEVM_URL}"
elif [[ -z "${EEST_ZKEVM_REPO:-}" && -z "${EEST_ZKEVM_VERSION:-}" && -z "${EEST_ZKEVM_ARTIFACT:-}" ]] && lock_value zkevm_url >/dev/null; then
  url="$(lock_value zkevm_url)"
else
  url="https://github.com/${repo}/releases/download/${url_version}/${artifact}"
fi

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
  rm -f "${tmp}"
  printf 'Downloading %s\n' "${url}"
  curl --fail --location --show-error --progress-bar --output "${tmp}" "${url}"
  verify_archive "${tmp}"
  mv "${tmp}" "${archive}"
else
  printf 'Using cached %s\n' "${archive}"
  verify_archive "${archive}"
fi

printf 'Extracting to %s\n' "${dest}"
tar -xzf "${archive}" -C "${dest}"

printf 'Done. Try:\n'
printf '  zig build zkevm -- %s/fixtures/blockchain_tests/<path>.json\n' "${dest}"
