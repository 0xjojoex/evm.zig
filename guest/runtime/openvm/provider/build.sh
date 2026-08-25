#!/bin/sh
set -eu

output=$1
manifest=$2
target_dir=$3
toolchain=${OPENVM_RUST_TOOLCHAIN:-openvm-1.94.1}
target=riscv64im-unknown-openvm-elf
provider_dir=$(dirname "$manifest")
rustc=$(rustup which rustc --toolchain "$toolchain")
toolchain_root=$(dirname "$(dirname "$rustc")")
host=$("$rustc" -vV | sed -n 's/^host: //p')
llvm_bin="$toolchain_root/lib/rustlib/$host/bin"

cd "$provider_dir"
RUSTC="$rustc" cargo build \
    --locked \
    --release \
    --manifest-path Cargo.toml \
    --target-dir "$target_dir"

input="$target_dir/$target/release/libevmz_openvm_crypto_provider.a"
objcopy=${LLVM_OBJCOPY:-$llvm_bin/llvm-objcopy}
nm=${LLVM_NM:-$llvm_bin/llvm-nm}
objdump=${LLVM_OBJDUMP:-$llvm_bin/llvm-objdump}
if [ ! -x "$objcopy" ]; then
    echo "OpenVM provider build requires llvm-objcopy; set LLVM_OBJCOPY to its path" >&2
    exit 1
fi

"$objcopy" --enable-deterministic-archives "$input" "$output"

formats=$("$objdump" -f "$output")
if ! printf '%s\n' "$formats" | grep -q 'file format elf64-littleriscv' ||
    printf '%s\n' "$formats" | grep 'file format' | grep -qv 'elf64-littleriscv' ||
    printf '%s\n' "$formats" | grep 'architecture:' | grep -qv 'riscv64'
then
    echo "OpenVM provider contains a non-RV64 object" >&2
    exit 1
fi

symbols=$("$nm" -g "$output")
for symbol in \
    _start \
    read_input \
    write_output \
    zkvm_keccak256 \
    zkvm_secp256k1_verify \
    zkvm_secp256k1_ecrecover \
    zkvm_sha256 \
    zkvm_ripemd160 \
    zkvm_blake2f \
    zkvm_modexp \
    zkvm_bls12_g1_add \
    zkvm_bls12_g1_msm \
    zkvm_bls12_g2_add \
    zkvm_bls12_g2_msm \
    zkvm_bls12_pairing \
    zkvm_bls12_map_fp_to_g1 \
    zkvm_bls12_map_fp2_to_g2 \
    zkvm_bn254_g1_add \
    zkvm_bn254_g1_mul \
    zkvm_bn254_pairing \
    zkvm_kzg_point_eval \
    zkvm_secp256r1_verify
do
    if ! printf '%s\n' "$symbols" | grep -Eq "[[:space:]]$symbol$"; then
        echo "OpenVM provider is missing $symbol" >&2
        exit 1
    fi
done
