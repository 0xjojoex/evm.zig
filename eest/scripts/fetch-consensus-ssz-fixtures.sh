#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
usage: scripts/fetch-consensus-ssz-fixtures.sh

Downloads the pinned consensus-spec General, Mainnet, and Minimal archives and
extracts only generic and static SSZ fixtures into the shared .eest cache.

Environment overrides:
  EVMZ_EEST_ROOT, CONSENSUS_VERSION, CONSENSUS_CACHE, CONSENSUS_DEST
  CONSENSUS_{GENERAL,MAINNET,MINIMAL}_{ARTIFACT,URL,SHA256}
USAGE
  exit 0
fi

lock_path=""
if [[ -f "../eest.lock" ]]; then
  lock_path="../eest.lock"
elif [[ -f "eest.lock" ]]; then
  lock_path="eest.lock"
else
  printf 'error: eest.lock not found\n' >&2
  exit 1
fi

lock_value() {
  local key="$1"
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

main_worktree() {
  git worktree list --porcelain | awk '
    /^worktree / { path=substr($0, 10) }
    /^branch refs\/heads\/main$/ { print path; exit }
  '
}

version="${CONSENSUS_VERSION:-$(lock_value consensus_version)}"
relative_dest="$(lock_value consensus_dest)"
default_worktree="$(main_worktree)"
if [[ -z "${default_worktree}" ]]; then
  default_worktree="$(git rev-parse --show-toplevel)"
fi
shared_root="${EVMZ_EEST_ROOT:-${default_worktree}/.eest}"
cache="${CONSENSUS_CACHE:-${shared_root}/cache}"
dest="${CONSENSUS_DEST:-${shared_root}/${relative_dest#.eest/}}"
mkdir -p "${cache}" "${dest}" "${dest}/ssz_generic"
tar_wildcard_args=()
if tar --help 2>&1 | grep -q -- '--wildcards'; then
  tar_wildcard_args+=(--wildcards)
fi

fetch_archive() {
  local artifact="$1"
  local url="$2"
  local expected_sha256="$3"
  local archive="${cache}/consensus-specs-${version}-${artifact}"
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

general_artifact="${CONSENSUS_GENERAL_ARTIFACT:-$(lock_value consensus_general_artifact)}"
general_url="${CONSENSUS_GENERAL_URL:-$(lock_value consensus_general_url)}"
general_sha256="${CONSENSUS_GENERAL_SHA256:-$(lock_value consensus_general_sha256)}"
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
  artifact="${!artifact_variable:-$(lock_value "consensus_${preset}_artifact")}"
  url="${!url_variable:-$(lock_value "consensus_${preset}_url")}"
  sha256="${!sha256_variable:-$(lock_value "consensus_${preset}_sha256")}"
  archive="$(fetch_archive "${artifact}" "${url}" "${sha256}")"
  printf 'Extracting %s static SSZ fixtures to %s\n' "${preset}" "${dest}/${preset}"
  tar -xzf "${archive}" \
    -C "${dest}" \
    --strip-components=1 \
    "${tar_wildcard_args[@]}" \
    "tests/${preset}/*/ssz_static/*"
done

printf 'Done. Run:\n'
printf '  EVMZ_EEST_ROOT=%q zig build ssz-conformance\n' "${shared_root}"
