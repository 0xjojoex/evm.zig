#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
config_root="${repo_root}/.zig-cache/zisk-config"
(
    cd "${repo_root}"
    zig build zisk-config --prefix "${config_root}" --summary none
)
# shellcheck disable=SC1091
source "${config_root}/share/evmz/zisk.env"

ZISK_HOME=${ZISK_HOME:-${HOME}/.zisk}
short_commit=${ZISK_COMMIT:0:7}
ZISK_SOURCE=${ZISK_SOURCE:-${ZISK_HOME}/src/zisk-${short_commit}}
provider="${ZISK_HOME}/evmz/zisk-${ZISK_VERSION}-${short_commit}/lib/libziskos_staticlib.a"

if [[ -s "${provider}" && "${FORCE_REBUILD:-false}" != true ]]; then
    printf '%s\n' "${provider}"
    exit 0
fi

rustup_bin="$(dirname "$(command -v rustup)")"
export PATH="${rustup_bin}:${ZISK_HOME}/bin:${PATH}"

identity="$("${ZISK_HOME}/bin/cargo-zisk" --version)"
[[ "${identity}" == *"${ZISK_VERSION}"* && "${identity}" == *"${short_commit}"* ]] || {
    printf 'error: expected cargo-zisk %s (%s), got %s\n' \
        "${ZISK_VERSION}" "${short_commit}" "${identity}" >&2
    exit 1
}

sysroot="$(RUSTUP_TOOLCHAIN=zisk rustc --print sysroot)"
[[ "${sysroot}" == "${ZISK_HOME}"/toolchains/* ]] || {
    printf 'error: rustc did not resolve the ZisK sysroot: %s\n' "${sysroot}" >&2
    exit 1
}

target_cfg="$(RUSTUP_TOOLCHAIN=zisk rustc --print cfg --target riscv64ima-zisk-zkvm-elf)"
for feature in zbb zbkb zbs; do
    grep -Fq "target_feature=\"${feature}\"" <<< "${target_cfg}" || {
        printf 'error: ZisK Rust target is missing %s\n' "${feature}" >&2
        exit 1
    }
done

if [[ ! -d "${ZISK_SOURCE}/.git" ]]; then
    [[ ! -e "${ZISK_SOURCE}" ]] || {
        printf 'error: ZISK_SOURCE exists but is not a git checkout: %s\n' "${ZISK_SOURCE}" >&2
        exit 1
    }
    mkdir -p "$(dirname "${ZISK_SOURCE}")"
    git init "${ZISK_SOURCE}" >&2
    git -C "${ZISK_SOURCE}" remote add origin https://github.com/0xPolygonHermez/zisk.git
    git -C "${ZISK_SOURCE}" fetch --depth 1 origin "${ZISK_COMMIT}" >&2
    git -C "${ZISK_SOURCE}" checkout --detach FETCH_HEAD >&2
fi

actual_commit="$(git -C "${ZISK_SOURCE}" rev-parse HEAD)"
[[ "${actual_commit}" == "${ZISK_COMMIT}" ]] || {
    printf 'error: expected ZisK source %s, got %s\n' "${ZISK_COMMIT}" "${actual_commit}" >&2
    exit 1
}

export CARGO_TARGET_RISCV64IMA_ZISK_ZKVM_ELF_RUSTFLAGS='-C target-feature=+unaligned-scalar-mem'
(
    cd "${ZISK_SOURCE}"
    "${ZISK_HOME}/bin/cargo-zisk" build --release -p ziskos-staticlib >&2
)

provider_source="$(find "${ZISK_SOURCE}/target/elf" -type f -name libziskos_staticlib.a -print -quit)"
[[ -s "${provider_source}" ]] || {
    printf 'error: provider build produced no libziskos_staticlib.a\n' >&2
    exit 1
}
mkdir -p "$(dirname "${provider}")"
install -m 0644 "${provider_source}" "${provider}"
printf '%s\n' "${provider}"
