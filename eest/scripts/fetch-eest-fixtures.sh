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
  EEST_SHA256     default: sha256 from ../eest.lock for the locked release
  EEST_DEST       default: dest from ../eest.lock
  EEST_CACHE      default: ../.eest/cache
  EEST_TRACKS     optional space-separated fixture directories to extract;
                  supported: state_tests transaction_tests blockchain_tests_sync
  EEST_PRUNE_OUT_OF_SCOPE
                   default: 1; excludes client/engine fixtures from extraction

Example:
  scripts/fetch-eest-fixtures.sh
  EEST_TRACKS="state_tests blockchain_tests_sync" scripts/fetch-eest-fixtures.sh
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
lock_sha256="$(lock_value sha256 || true)"

repo="${EEST_REPO:-${lock_repo:-ethereum/execution-specs}}"
version="${EEST_VERSION:-${lock_version:-tests-glamsterdam-devnet@v6.1.0}}"
artifact="${EEST_ARTIFACT:-${lock_artifact:-fixtures_glamsterdam-devnet.tar.gz}}"
version_slug="${version//@/-}"
url_version="${version//@/%40}"
dest="${EEST_DEST:-$(lock_path_value dest || printf '../.eest/fixtures/%s' "${version_slug}")}"
cache="${EEST_CACHE:-../.eest/cache}"
tracks="${EEST_TRACKS:-}"
prune_out_of_scope="${EEST_PRUNE_OUT_OF_SCOPE:-1}"
if [[ -n "${EEST_URL:-}" ]]; then
  url="${EEST_URL}"
elif [[ -z "${EEST_REPO:-}" && -z "${EEST_VERSION:-}" && -z "${EEST_ARTIFACT:-}" && -n "${lock_url}" ]]; then
  url="${lock_url}"
else
  url="https://github.com/${repo}/releases/download/${url_version}/${artifact}"
fi
if [[ -n "${EEST_SHA256:-}" ]]; then
  sha256="${EEST_SHA256}"
elif [[ -z "${EEST_REPO:-}" && -z "${EEST_VERSION:-}" && -z "${EEST_ARTIFACT:-}" && -z "${EEST_URL:-}" ]]; then
  sha256="${lock_sha256}"
else
  sha256=""
fi
archive="${cache}/${version_slug}-${artifact}"
out_of_scope_tracks=(
  "fixtures/blockchain_tests"
  "fixtures/blockchain_tests_engine"
  "fixtures/blockchain_tests_engine_x"
)
track_patterns=()
if [[ -n "${tracks}" ]]; then
  read -r -a selected_tracks <<< "${tracks}"
  for track in "${selected_tracks[@]}"; do
    case "${track}" in
      state_tests|transaction_tests|blockchain_tests_sync) ;;
      *)
        printf 'unsupported EEST track: %s\n' "${track}" >&2
        exit 1
        ;;
    esac
    track_patterns+=("fixtures/${track}/*")
  done
fi

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

mkdir -p "${cache}" "${dest}"

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
if [[ -n "${tracks}" ]]; then
  if tar --version 2>/dev/null | head -1 | grep -qi 'bsdtar'; then
    include_args=()
    for pattern in "${track_patterns[@]}"; do
      include_args+=("--include=${pattern}")
    done
    tar -xzf "${archive}" -C "${dest}" "${include_args[@]}"
  else
    tar --wildcards -xzf "${archive}" -C "${dest}" "${track_patterns[@]}"
  fi
else
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
fi

printf 'Done. Try:\n'
printf '  zig build eest -- %s/fixtures/state_tests/<path>.json\n' "${dest}"
