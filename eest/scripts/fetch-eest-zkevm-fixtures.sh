#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-zkevm-fixtures.sh [--manifest PATH] [--resolved-manifest PATH]

Downloads EEST zkEVM blockchain fixtures into ../.eest/.
With --manifest, extracts only the archive-relative paths listed in PATH.
With --resolved-manifest, records the verified corpus identity, counts, and
fixture roots.

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
  zig build zkevm -- ../.eest/fixtures/tests-zkevm-v0.8.0/fixtures/blockchain_tests/path/to/test.json
USAGE
}

manifest=""
resolved_manifest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --manifest)
      [[ $# -ge 2 ]] || { printf 'error: --manifest needs a path\n' >&2; exit 2; }
      manifest="$2"
      shift 2
      ;;
    --resolved-manifest)
      [[ $# -ge 2 ]] || { printf 'error: --resolved-manifest needs a path\n' >&2; exit 2; }
      resolved_manifest="$2"
      shift 2
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

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
version="${EEST_ZKEVM_VERSION:-$(lock_value zkevm_version || printf 'tests-zkevm@v0.8.0')}"
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
if [[ -z "${manifest}" ]]; then
  tar -xzf "${archive}" -C "${dest}"
else
  [[ -f "${manifest}" ]] || { printf 'error: manifest not found: %s\n' "${manifest}" >&2; exit 1; }
  fixtures=()
  while IFS= read -r fixture || [[ -n "${fixture}" ]]; do
    fixture="${fixture%$'\r'}"
    [[ -z "${fixture}" || "${fixture}" == \#* ]] && continue
    case "${fixture}" in
      fixtures/*.json) ;;
      *) printf 'error: invalid fixture path in manifest: %s\n' "${fixture}" >&2; exit 1 ;;
    esac
    fixtures+=("${fixture}")
  done < "${manifest}"
  [[ ${#fixtures[@]} -gt 0 ]] || { printf 'error: manifest is empty: %s\n' "${manifest}" >&2; exit 1; }
  tar -xzf "${archive}" -C "${dest}" "${fixtures[@]}"
fi

if [[ -n "${resolved_manifest}" ]]; then
  [[ -z "${manifest}" ]] || {
    printf 'error: --resolved-manifest requires the complete corpus\n' >&2
    exit 2
  }
  command -v jq >/dev/null || { printf 'error: jq is required for --resolved-manifest\n' >&2; exit 1; }
  [[ -n "${sha256}" ]] || { printf 'error: resolved corpus requires a pinned SHA-256\n' >&2; exit 1; }

  spec_version="$(lock_value version)"
  [[ "${spec_version}" =~ ^tests-[a-z0-9]+(-[a-z0-9]+)*@v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'error: invalid specification fixture release: %s\n' "${spec_version}" >&2
    exit 1
  }
  spec_track="${spec_version#tests-}"
  spec_track="${spec_track%@v*}"
  spec_release="${spec_version##*@v}"
  network="${spec_track}"
  if [[ "${spec_track}" == *-devnet ]]; then
    network="${spec_track}-${spec_release%%.*}"
  fi

  blockchain_root="${dest}/fixtures/blockchain_tests"
  index="${dest}/fixtures/.meta/index.json"
  [[ -d "${blockchain_root}" ]] || { printf 'error: missing blockchain fixtures\n' >&2; exit 1; }
  [[ -f "${index}" ]] || { printf 'error: missing fixture index\n' >&2; exit 1; }
  fixture_files="$(find "${blockchain_root}" -type f -name '*.json' | wc -l)"
  indexed_files="$(jq '[.test_cases[] | select(.format == "blockchain_test") | .json_path] | unique | length' "${index}")"
  indexed_tests="$(jq '[.test_cases[] | select(.format == "blockchain_test")] | length' "${index}")"
  fixture_count="$({
    find "${blockchain_root}" -type f -name '*.json' -print0 \
      | xargs -0 -n 64 jq -r \
        '[.. | objects | .statelessInputBytes? | select(type == "string")] | length'
  } | awk '{ total += $1 } END { print total + 0 }')"
  [[ "${fixture_files}" -gt 0 && "${fixture_files}" -eq "${indexed_files}" ]]
  [[ "${indexed_tests}" -gt 0 && "${fixture_count}" -gt 0 ]]

  mkdir -p "$(dirname "${resolved_manifest}")"
  fixture_root="$(cd "${blockchain_root}" && pwd)"
  jq -n \
    --arg id "${version}" \
    --arg digest "${sha256}" \
    --arg fixture_release "${spec_version}" \
    --arg network "${network}" \
    --arg validation_ref "${version}" \
    --arg fixture_root "${fixture_root}" \
    --argjson fixture_files "${fixture_files}" \
    --argjson indexed_tests "${indexed_tests}" \
    --argjson fixture_count "${fixture_count}" \
    '{
      schema_version: 1,
      mode: "tests-zkevm",
      id: $id,
      corpus_digest: $digest,
      fixture_release: $fixture_release,
      network: $network,
      workload: { eest_validation_ref: $validation_ref },
      fixture_roots: [$fixture_root],
      fixture_files: $fixture_files,
      indexed_tests: $indexed_tests,
      fixture_count: $fixture_count
    }' > "${resolved_manifest}"
fi

printf 'Done. Try:\n'
printf '  zig build zkevm -- %s/fixtures/blockchain_tests/<path>.json\n' "${dest}"
