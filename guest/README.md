# zkVM guests

The stateless validator compiles to RV64 ELFs for ZisK, SP1, and OpenVM. All
three backends share the `zkvm_accelerators.h` C ABI and let the linked zkVM
runtime own `_start`; Zig exports `main` and the validator payload.

A shipped guest ELF validates one pinned specification. Devnet releases use the
compatibility tag `guest-<track>@vX.Y.Z[-rc.N]` (mirroring `tests-<track>@vX.Y.Z`
rather than evmz SemVer), and each backend manifest records the accepted schema
id, corpus release, ELF SHA-256, and verification key. See
[`RELEASING.md`](../RELEASING.md) for the release and signing workflow.

## Backends at a glance

| Backend | Pinned version | Rust toolchain | Target features | Heap model | Build step |
| --- | --- | --- | --- | --- | --- |
| ZisK | `v1.3.2-alpha` | `zisk-4.0.0` | `RV64IM` + `Zbb`, `Zbs`, `Zbkb`, `Zicclsm`, `unaligned_scalar_mem` | Fixed (`-Dguest-heap-bytes`, default 480 MiB) | `zig build guest-zisk` |
| SP1 | `v6.9.0` (ERE `v0.19.5`) | `succinct-1.96.0-64bit-v3` | `RV64IM` | Shared platform heap | `zig build guest-sp1` |
| OpenVM | `v2.1.0-preview` (ERE `v0.19.5`) | `openvm-1.94.1` | `RV64IM` + `Zicclsm`, `unaligned_scalar_mem` | Shared platform heap | `zig build guest-openvm` |

The native benchmark hosts and their shared protocol live in one Cargo
workspace at `guest/runtime/Cargo.toml` (its OpenVM host uses ERE's Plonky3
compatibility patch so SP1 and OpenVM coexist). Guest provider crates remain
standalone because each builds a static archive with its backend's custom Rust
toolchain.

## Building

### ZisK

Install the ZisK `v1.3.2-alpha` SDK and the `zisk-4.0.0` Rust toolchain
(`cargo-zisk toolchain install --toolchain-version zisk-4.0.0`; `zig build zisk-config`
prints the exact source pin). Then build the static runtime archive and link the
guest ELF:

```sh
provider=$(guest/runtime/zisk/build_provider.sh)
zig build guest-zisk -Dguest-payload=stateless-ere -Doptimize=fast \
  -Dstateless-schema=0x1501 \
  -Dziskos-staticlib="$provider"
```

`build_provider.sh` builds the pinned ZisK commit with
`CARGO_TARGET_RISCV64IMA_ZISK_ZKVM_ELF_RUSTFLAGS="-C target-feature=+unaligned-scalar-mem"`
and caches the archive under `~/.zisk/evmz/` (set `ZISK_SOURCE` to reuse a local
checkout). Building without that target feature changes the ELF and verification
key.

ZisK stays on its direct `ziskos-staticlib` archive rather than routing through
ERE's wrapper crate, which adds no separate accelerator implementation.

### SP1

Install the SP1 `v6.9.0` toolchain (`succinct-1.96.0-64bit-v3`) once:

```sh
curl -L https://sp1up.succinct.xyz | bash
~/.sp1/bin/sp1up -v v6.9.0
```

`guest-sp1` compiles the repo-owned ERE `v0.19.5` SP1 platform and `libzkevm`
accelerator archive automatically (or pass `-Dsp1-staticlib=/path/to/provider.a`
to override):

```sh
zig build guest-sp1 -Dguest-payload=stateless-ere -Doptimize=fast

zig build guest-sp1-run -Dguest-payload=stateless-ere -Doptimize=fast \
  -Dguest-input=/path/to/raw-stateless-input.bin \
  -Dguest-output=/path/to/public-values.bin
```

`guest-sp1-run` uses `sp1-core-executor` `6.9.0` and reports deterministic
execute-only instruction cycles (not proof cycles or proving time).

### OpenVM

Install `cargo-openvm` at `v2.1.0-preview` and its `openvm-1.94.1` toolchain,
then build the guest ELF:

```sh
cargo install --locked \
  --git https://github.com/openvm-org/openvm.git \
  --tag v2.1.0-preview cargo-openvm
cargo openvm toolchain install

zig build guest-openvm -Dguest-payload=stateless-ere -Doptimize=fast \
  -Dstateless-schema=0x1501
```

The build links OpenVM's startup and ERE `v0.19.5`'s `ere-platform-openvm`
(`openvm-accelerators`), verifying startup, I/O, and accelerator symbols before
linking. Because OpenVM's startup calls a `void` `main`, guest validation
failures surface as missing or mismatched public output rather than a non-zero
exit code.

## Input schema and public output

The `stateless-ere` payload decodes `schema_id || payload` input, where the
two-byte id packs `fork_index || revision`. `-Dstateless-schema=0x1501`
(repeatable) selects which ids the router compiles into the ELF; omitting it
compiles all known schemas. Shipped guests should pin the schema explicitly so
only one specialized `Validator` is linked.

On success, `stateless-ere` writes the raw SSZ `StatelessValidationResult`,
matching `ere-guests` and `zkevm-benchmark-workload`. On ZisK, bytes after the
SSZ result in the 256-byte public-output region are zero-padded.

## Memory model

- **ZisK:** Allocates from a fixed-capacity buffer sized by
  `-Dguest-heap-bytes=<bytes>` (default 480 MiB) within a total RAM envelope
  (`-Dguest-zisk-ram-bytes=<bytes>`, defaulting to ZisK's declared RAM top).
  Increasing the linker reservation changes neither ELF size nor execution cost.
- **SP1 and OpenVM:** Route Zig allocations through the shared platform heap
  used by ERE and the Rust accelerator provider (`_end` to the backend's
  reserved input/memory boundary).

These defaults are a conformance envelope, not a mainnet sizing claim. Size
deployment artifacts from profiled replays of target workloads.

## Host semantic gate

Run the full unit test suite through the zkVM accelerator adapters on the host
without an RV64 toolchain:

```sh
zig build test-evmz-zkvm --summary all
```

This links a host-native test double for every symbol in `zkvm_accelerators.h`
to verify adapter semantics.

## Benchmarking and corpus qualification

Run EEST `tests-zkevm` fixtures through any persistent guest host locally:

```sh
zig build zkevm-resolve
zig build zkevm -- \
  --corpus-manifest .zig-cache/eest-consume/zkevm-corpus.json \
  --executor zisk \
  --zisk-host /path/to/evmz-zisk-host \
  --zisk-elf zig-out/guest/zisk/evmz-guest-zisk.elf
```

Pass `--executor sp1` (`--sp1-host`, `--sp1-elf`) or `--executor openvm`
(`--openvm-host`, `--openvm-elf`, `--openvm-config`) for the other backends.
Add `--evidence-dir <dir>` to write `evidence.json` and `--strict-evidence` to
enforce the pinned corpus hash.

Each worker reuses one persistent host process so ELF parsing/ROM setup happens
once. The benchmark hosts invoke backend executors directly (without
initializing `ere-prover-*` proving keys) and report backend-specific counters:

- **ZisK:** total steps (Rust emulator; ERE AOT timings on Linux `x86_64` require `/dev/shm` and separate measurement)
- **SP1:** execute-only instruction cycles
- **OpenVM:** retired instructions and trace cells

Counters across different zkVMs are not numerically comparable, and emulator
wall time is not proving time. See [`RELEASING.md`](../RELEASING.md#guest-releases)
for how CI qualifies and signs backend release artifacts.

## ZisK constraint and proof verification

An emulator run checks public output but not prover constraints. Before running
a full proof on ZisK, check constraints against the proving key at
`${ZISK_HOME}/provingKey`:

```sh
cargo-zisk-dev verify-constraints \
  --elf zig-out/guest/zisk/evmz-guest-zisk.elf \
  --inputs /path/to/stdin.bin \
  --proving-key "${ZISK_HOME}/provingKey"

cargo-zisk prove \
  --elf zig-out/guest/zisk/evmz-guest-zisk.elf \
  --inputs /path/to/stdin.bin \
  --proving-key "${ZISK_HOME}/provingKey" \
  --output /path/to/proof.bin \
  --verify-proof

cargo-zisk verify --proof /path/to/proof.bin
```

Build the persistent ZisK benchmark host from the workspace with:

```sh
cargo build --release --manifest-path guest/runtime/Cargo.toml -p evmz-zisk-host
```
