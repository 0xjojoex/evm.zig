#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/consensus-lock.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
usage: scripts/fetch-consensus-ssz-fixtures.sh

Downloads the pinned consensus-spec General, Mainnet, and Minimal archives and
extracts only generic and static SSZ fixtures into the consensus cache.

Environment overrides:
  EVMZ_CONSENSUS_ROOT, CONSENSUS_REPO, CONSENSUS_RELEASE, CONSENSUS_CACHE,
  CONSENSUS_DEST
  CONSENSUS_{GENERAL,MAINNET,MINIMAL}_{ARTIFACT,URL,SHA256}
USAGE
  exit 0
fi

main_worktree() {
  git worktree list --porcelain | awk '
    /^worktree / { path=substr($0, 10) }
    /^branch refs\/heads\/main$/ { print path; exit }
  '
}

repo="${CONSENSUS_REPO:-$(consensus_lock_value repo)}"
release="${CONSENSUS_RELEASE:-$(consensus_lock_value release)}"
default_worktree="$(main_worktree)"
if [[ -z "${default_worktree}" ]]; then
  default_worktree="$(git rev-parse --show-toplevel)"
fi
shared_root="${EVMZ_CONSENSUS_ROOT:-${default_worktree}/eest/.consensus}"
cache="${CONSENSUS_CACHE:-${shared_root}/cache}"
dest="${CONSENSUS_DEST:-${shared_root}/${release}}"
mkdir -p "${cache}" "${dest}" "${dest}/ssz_generic"
tar_supports_wildcards=false
if tar --help 2>&1 | grep -q -- '--wildcards'; then
  tar_supports_wildcards=true
fi

fetch_archive() {
  local artifact="$1"
  local url="$2"
  local expected_sha256="$3"
  local archive="${cache}/consensus-specs-${release}-${artifact}"
  if [[ ! -f "${archive}" ]]; then
    printf 'Downloading %s\n' "${url}" >&2
    curl --fail --location --show-error --progress-bar --output "${archive}.tmp" "${url}"
    verify_archive "${archive}.tmp" "${expected_sha256}"
    mv "${archive}.tmp" "${archive}"
  else
    printf 'Using cached %s\n' "${archive}" >&2
    verify_archive "${archive}" "${expected_sha256}"
  fi
  printf '%s\n' "${archive}"
}

verify_archive() {
  local archive="$1"
  local expected="$2"
  local actual=""
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${archive}" | awk '{print $1}')"
  else
    printf 'error: shasum or sha256sum is required\n' >&2
    return 1
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'error: checksum mismatch for %s\nexpected: %s\nactual:   %s\n' \
      "${archive}" "${expected}" "${actual}" >&2
    return 1
  fi
}

general_artifact="${CONSENSUS_GENERAL_ARTIFACT:-$(consensus_lock_value general_artifact)}"
general_url="${CONSENSUS_GENERAL_URL:-$(consensus_release_url "${repo}" "${release}" "${general_artifact}")}"
general_sha256="${CONSENSUS_GENERAL_SHA256:-$(consensus_lock_value general_sha256)}"
general_archive="$(fetch_archive "${general_artifact}" "${general_url}" "${general_sha256}")"
printf 'Extracting General SSZ fixtures to %s\n' "${dest}/ssz_generic"
tar -xzf "${general_archive}" \
  -C "${dest}/ssz_generic" \
  --strip-components=4 \
  tests/general/phase0/ssz_generic

for preset in mainnet minimal; do
  uppercase_preset="$(printf '%s' "${preset}" | tr '[:lower:]' '[:upper:]')"
  artifact_variable="CONSENSUS_${uppercase_preset}_ARTIFACT"
  url_variable="CONSENSUS_${uppercase_preset}_URL"
  sha256_variable="CONSENSUS_${uppercase_preset}_SHA256"
  artifact="${!artifact_variable:-$(consensus_lock_value "${preset}_artifact")}"
  url="${!url_variable:-$(consensus_release_url "${repo}" "${release}" "${artifact}")}"
  sha256="${!sha256_variable:-$(consensus_lock_value "${preset}_sha256")}"
  archive="$(fetch_archive "${artifact}" "${url}" "${sha256}")"
  printf 'Extracting %s static SSZ fixtures to %s\n' "${preset}" "${dest}/${preset}"
  if [[ "${tar_supports_wildcards}" == true ]]; then
    tar -xzf "${archive}" \
      -C "${dest}" \
      --strip-components=1 \
      --wildcards \
      "tests/${preset}/*/ssz_static/*"
  else
    tar -xzf "${archive}" \
      -C "${dest}" \
      --strip-components=1 \
      "tests/${preset}/*/ssz_static/*"
  fi
done

printf 'Done. Run:\n'
printf '  EVMZ_CONSENSUS_ROOT=%q zig build ssz-conformance\n' "${shared_root}"
