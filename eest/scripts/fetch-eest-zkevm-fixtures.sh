#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/eest-lock.sh"

usage() {
  cat <<'USAGE'
usage: scripts/fetch-eest-zkevm-fixtures.sh [--benchmark] [--mutations | --steps | --manifest PATH] [--resolved-manifest PATH]

Downloads EEST zkEVM conformance or benchmark blockchain fixtures into ../.eest/.
With --benchmark, selects the locked tests-zkevm-benchmark release.
With --manifest, extracts only the archive-relative paths listed in PATH.
With --resolved-manifest, records the verified corpus identity, counts, and
fixture roots.

Environment overrides:
  EEST_ZKEVM_REPO      repository override
  EEST_ZKEVM_RELEASE   release override
  EEST_ZKEVM_ARTIFACT  artifact override
  EEST_ZKEVM_URL       download URL override
  EEST_ZKEVM_SHA256    checksum override
  EEST_ZKEVM_DEST      extraction destination override
  EEST_CACHE           shared archive cache override

Example:
  scripts/fetch-eest-zkevm-fixtures.sh
  scripts/fetch-eest-zkevm-fixtures.sh --benchmark
  scripts/fetch-eest-zkevm-fixtures.sh --mutations
  zig build zkevm
USAGE
}

manifest=""
resolved_manifest=""
benchmark=false
preset_manifest=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --benchmark)
      benchmark=true
      shift
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
    --mutations)
      manifest="$(eest_lock_path zkevm_mutations_manifest)"
      preset_manifest=true
      shift
      ;;
    --steps)
      manifest="$(eest_lock_path zkevm_steps_manifest)"
      preset_manifest=true
      shift
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${benchmark}" == true && "${preset_manifest}" == true ]]; then
  printf 'error: --benchmark cannot be combined with --mutations or --steps\n' >&2
  exit 2
fi

if [[ "${benchmark}" == true ]]; then
  lock_prefix="zkevm_benchmark"
  dest_track="zkevm_benchmark"
  manifest_mode="tests-zkevm-benchmark"
else
  lock_prefix="zkevm"
  dest_track="zkevm"
  manifest_mode="tests-zkevm"
fi

repo="${EEST_ZKEVM_REPO:-$(eest_lock_value "${lock_prefix}_repo")}"
release="${EEST_ZKEVM_RELEASE:-$(eest_lock_value "${lock_prefix}_release")}"
artifact="${EEST_ZKEVM_ARTIFACT:-$(eest_lock_value "${lock_prefix}_artifact")}"
release_slug="$(eest_release_slug "${release}")"
dest="${EEST_ZKEVM_DEST:-$(eest_release_path "${dest_track}" "${release}")}"
cache="${EEST_CACHE:-${EEST_LOCK_REPO_ROOT}/.eest/cache}"
archive="${cache}/${release_slug}-${artifact}"

if [[ -n "${EEST_ZKEVM_SHA256:-}" ]]; then
  sha256="${EEST_ZKEVM_SHA256}"
elif [[ -z "${EEST_ZKEVM_REPO:-}" && -z "${EEST_ZKEVM_RELEASE:-}" && -z "${EEST_ZKEVM_ARTIFACT:-}" && -z "${EEST_ZKEVM_URL:-}" ]]; then
  sha256="$(eest_lock_value "${lock_prefix}_sha256")"
else
  sha256=""
fi

if [[ -n "${EEST_ZKEVM_URL:-}" ]]; then
  url="${EEST_ZKEVM_URL}"
else
  url="$(eest_release_url "${repo}" "${release}" "${artifact}")"
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

  if [[ "${benchmark}" == true ]]; then
    fixture_release="$(eest_lock_value zkevm_release)"
    network="Amsterdam"
    validation_ref="${fixture_release}"
  else
    fixture_release="$(eest_lock_value state_release)"
    spec_track="${fixture_release#tests-}"
    spec_track="${spec_track%@v*}"
    spec_release="${fixture_release##*@v}"
    network="${spec_track}"
    if [[ "${spec_track}" == *-devnet ]]; then
      network="${spec_track}-${spec_release%%.*}"
    fi
    validation_ref="${release}"
  fi
  [[ "${fixture_release}" =~ ^tests-[a-z0-9]+(-[a-z0-9]+)*@v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'error: invalid specification fixture release: %s\n' "${fixture_release}" >&2
    exit 1
  }

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
    --arg id "${release}" \
    --arg digest "${sha256}" \
    --arg mode "${manifest_mode}" \
    --arg fixture_release "${fixture_release}" \
    --arg network "${network}" \
    --arg validation_ref "${validation_ref}" \
    --arg fixture_root "${fixture_root}" \
    --argjson fixture_files "${fixture_files}" \
    --argjson indexed_tests "${indexed_tests}" \
    --argjson fixture_count "${fixture_count}" \
    '{
      schema_version: 1,
      mode: $mode,
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
