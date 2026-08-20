#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/eest-lock.sh"

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-fixtures.sh

Downloads generated EEST JSON fixtures into ../.eest/, which is gitignored.

Environment overrides:
  EEST_STATE_REPO      repository override
  EEST_STATE_RELEASE   release override
  EEST_STATE_ARTIFACT  artifact override
  EEST_STATE_URL       download URL override
  EEST_STATE_SHA256    checksum override
  EEST_STATE_DEST      extraction destination override
  EEST_CACHE           shared archive cache override
  EEST_TRACKS     optional space-separated fixture directories to extract;
                  supported: state_tests transaction_tests blockchain_tests_sync
  EEST_PRUNE_OUT_OF_SCOPE
                   default: 1; excludes client/engine fixtures from extraction

Example:
  scripts/fetch-eest-fixtures.sh
  EEST_TRACKS="state_tests blockchain_tests_sync" scripts/fetch-eest-fixtures.sh
  zig build eest

State fixture defaults come from the authoritative state track in eest.lock.
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

repo="${EEST_STATE_REPO:-$(eest_lock_value state_repo)}"
release="${EEST_STATE_RELEASE:-$(eest_lock_value state_release)}"
artifact="${EEST_STATE_ARTIFACT:-$(eest_lock_value state_artifact)}"
release_slug="$(eest_release_slug "${release}")"
dest="${EEST_STATE_DEST:-$(eest_release_path state "${release}")}"
cache="${EEST_CACHE:-${EEST_LOCK_REPO_ROOT}/.eest/cache}"
tracks="${EEST_TRACKS:-}"
prune_out_of_scope="${EEST_PRUNE_OUT_OF_SCOPE:-1}"
if [[ -n "${EEST_STATE_URL:-}" ]]; then
  url="${EEST_STATE_URL}"
else
  url="$(eest_release_url "${repo}" "${release}" "${artifact}")"
fi
if [[ -n "${EEST_STATE_SHA256:-}" ]]; then
  sha256="${EEST_STATE_SHA256}"
elif [[ -z "${EEST_STATE_REPO:-}" && -z "${EEST_STATE_RELEASE:-}" && -z "${EEST_STATE_ARTIFACT:-}" && -z "${EEST_STATE_URL:-}" ]]; then
  sha256="$(eest_lock_value state_sha256)"
else
  sha256=""
fi
archive="${cache}/${release_slug}-${artifact}"
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
