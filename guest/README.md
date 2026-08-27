# zkVM guests

The stateless validator compiles to RV64 ELFs for ZisK, SP1, and OpenVM. All
three backends share the `zkvm_accelerators.h` ABI and let the linked zkVM
runtime own `_start`; Zig exports `main` and the validator payload.

A guest ELF validates exactly one specification, so devnet releases use the
compatibility coordinate `guest-<track>@vX.Y.Z[-rc.N]`. The version mirrors the
complete upstream fixture release: `guest-<track>@vX.Y.Z-rc.0` pairs with
`tests-<track>@vX.Y.Z`; it is not evmz software SemVer.
The independently numbered `tests-zkevm` wire/corpus release is also recorded.
Devnet tracks carry no compatibility guarantee at any bump; the release
manifest states what an ELF proves, the stateless schema id is the wire
compatibility token, and each backend verification key identifies its exact
ELF bytes. See
[the release policy](https://github.com/0xjojoex/evm.zig/blob/main/RELEASING.md).

## Building

The native benchmark hosts and their shared protocol are one Cargo workspace at
`guest/runtime/Cargo.toml`. Its OpenVM host follows ERE's compatibility patch,
which places OpenVM's stable Plonky3 crates on a separate Git source from SP1's
`0.4.3-succinct` crates. Guest provider crates remain standalone because their
locks define static archives built by backend-specific Rust toolchains.

Zig codegen follows each backend's effective guest policy: ZisK enables Zbb,
Zbs, Zbkb, and the screened efficient-unaligned-memory tuning; SP1 remains
RV64IM; OpenVM enables Zicclsm and efficient unaligned scalar memory. Zig
spells the last LLVM feature `unaligned_scalar_mem`, while Rust spells it
`unaligned-scalar-mem`. ZisK's A and custom DMA extensions remain properties
of its linked runtime rather than of evmz Zig code.

`guest-zisk` builds the selected payload as a ZisK RV64 ELF. A real
`libziskos_staticlib.a` provider is required:

```sh
provider=$(guest/runtime/zisk/build_provider.sh)
zig build guest-zisk -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dstateless-schema=0x1501 \
  -Dziskos-staticlib="$provider"
```

`build_provider.sh` uses the same version and source commit as CI, ensures the
ZisK Rust target resolves through rustup instead of a system Rust installation,
and caches the provider under `~/.zisk/evmz/`. Override `ZISK_SOURCE` to reuse
an existing checkout of the pinned commit. The provider is built with
`CARGO_TARGET_RISCV64IMA_ZISK_ZKVM_ELF_RUSTFLAGS="-C target-feature=+unaligned-scalar-mem"`.
The pinned CI build uses this target policy. A provider built without it produces
a different guest ELF and verification key.

SP1 uses the repo-owned ERE v0.16.3 platform provider. Install the matching
SP1 v6.4.0 toolchain once:

```sh
curl -L https://sp1up.succinct.xyz | bash
~/.sp1/bin/sp1up -v v6.4.0
```

The guest build compiles ERE's SP1 platform and its `libzkevm` accelerator ABI
into a static archive before linking Zig. It follows ERE's current SP1 guest
patch for the unreleased standards-conformance fixes in SP1 #2865.

```sh
zig build guest-sp1 -Dguest-payload=stateless-ere -Doptimize=ReleaseFast

zig build guest-sp1-run -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dguest-input=/path/to/raw-stateless-input.bin \
  -Dguest-output=/path/to/public-values.bin
```

`-Dsp1-staticlib=/path/to/provider.a` remains available as an explicit archive
override. The SP1 host driver is locked to `sp1-core-executor` 6.4.0. It
reports deterministic execute-only instruction cycles — not proof cycles or
proving time.

OpenVM `v2.1.0-preview` requires its `openvm-1.94.1` Rust toolchain. Install it
with the matching `cargo-openvm`, then build the RV64 guest:

```sh
cargo install --locked \
  --git https://github.com/openvm-org/openvm.git \
  --tag v2.1.0-preview cargo-openvm
cargo openvm toolchain install

zig build guest-openvm -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dstateless-schema=0x1501
```

The build links OpenVM's official startup and ERE v0.16.3's
`ere-platform-openvm` implementation of the accelerator ABI. The repo-owned
Rust crate only bridges Zig input and output to that platform. Its build checks
the startup, I/O, and accelerator symbols before linking.

OpenVM's startup calls a void `main`. Guest validation failures therefore
appear as missing or mismatched public output rather than a process exit status.
EEST remains the correctness check for every fixture. Direct fixture and A/B
runs live in the `openvm-guest-screen` skill, outside the guest build graph.
OpenVM metrics are not numerically comparable with ZisK steps or SP1 cycles.

## Input schema

The `stateless-ere` payload decodes `schema_id || payload` input, where the
two-byte id packs `fork_index || revision`. `-Dstateless-schema=0x1501`
(repeatable) picks which ids the build's router accepts; unset enables every
schema evmz implements. Pin it explicitly for a shipped guest: each enabled
fork compiles its own specialized `Validator` into the ELF, and an id the
router cannot resolve is a compile error rather than a runtime rejection.

## Memory

ZisK payloads allocate from a fixed-capacity heap chosen with
`-Dguest-heap-bytes=<bytes>`, defaulting to 480 MiB. SP1 and OpenVM instead route
Zig allocations through the platform allocator used by ERE and the Rust
accelerator provider. Input, Zig state, and accelerator allocations therefore
share one heap from `_end` to each backend's reserved input or memory boundary.

Post-run SP1 and OpenVM memory scans cover their shared platform heap. ZisK
additionally takes a total RAM envelope with
`-Dguest-zisk-ram-bytes=<bytes>`, defaulting to end at ZisK's declared RAM top.
Fixed capacity is free: its linker reservation changes neither the ELF bytes nor
the execution cost.

These defaults are a conformance envelope, not a production-mainnet memory
claim. Size a deployment artifact from profiled replay of its real witness/block
workload, and retain an explicit failure when that fixed capacity is exceeded.

## Host semantic gate

Run the full root suite through the zkVM adapters without building an RV64
guest:

```sh
zig build test-evmz-zkvm --summary all
```

This links a host-native implementation of every symbol in
`zkvm_accelerators.h` and exercises the zkVM adapters against those
semantics. The provider is a correctness test double, not a guest-performance
model; `guest-zisk` still requires the real `libziskos_staticlib.a`.

## Guest benchmark CI

The `Guest benchmark` workflow is the execute-only guest performance path.
Automatic runs remain ZisK-only. Manual dispatches can run SP1 or OpenVM
against the same `tests-zkevm@vX.Y.Z` corpus. Correctness gates every backend:
the corpus must be complete and every public output must match. Metrics from
different zkVMs are kept separate, and emulator execution duration is not
proving time.

Reports are absolute: the workflow measures the candidate ELF and does not
compare against a release. The `zkevm` command writes backend-neutral ERE rows,
an aggregated report, and one `evidence.json`. Reports identify the backend's
primary metric, optional secondary metric, and execution duration; there is no
separate reporting script or stored release baseline.

`Guest release` qualifies and signs one selected backend against the strict
corpus. ZisK, SP1, and OpenVM runs may execute in parallel; only their short
draft updates are serialized. Each run verifies its tested ELF, generates the
VK with the digest-pinned ERE 0.16.3 server image, and signs the ELF, VK, and
backend manifest. The manifest records the source, qualification run, keygen
image, compatibility identity, and hashes of the ELF, VK, evidence, and report.
Its signature is the completed-slot marker.

The first completed run uses the requested Git tag, creating it if absent, and
creates the draft. Rerunning a backend replaces only that backend's draft slot
and uploads the signed manifest last. Existing signed slots must use the same
schema and corpus. Review the three signed slots in the draft, then publish the
prerelease manually in GitHub. Backend qualification commits may differ and
may be outside `main`; their signed manifests and evidence retain the
byte-level provenance. The guest version is shared, matching `ere-guests`'
`artifacts[]` model.

`zig build zkevm -- --executor zisk|sp1|openvm` runs the same ERE-shaped
measurements locally. All three use the same persistent host protocol and
cache the parsed or compiled ELF per worker. Pass `--zisk-host`/`--zisk-elf`
or `--sp1-host`/`--sp1-elf` and fixture paths. OpenVM additionally needs
`--openvm-config`. `--evidence-dir` enables the release evidence path used by
CI for any guest backend; `--strict-evidence` additionally requires the pinned
`tests-zkevm` corpus identity.

The common response carries a primary counter, a secondary counter, elapsed
execution time, and public output. The counter meanings are deliberately
backend-specific: ZisK steps and zero, SP1 cycles and zero, or OpenVM retired
instructions and trace cells.

The benchmark hosts call the backend executors directly instead of constructing
an `ere-prover-*` instance. ERE's prover constructors also initialize proving
or key-generation state, while this path only needs repeated execution and
backend-native counters. Release key generation still uses the matching ERE
server image.

ZisK stays on its direct, exact-commit `ziskos-staticlib` build. ERE's ZisK
platform is a thin wrapper over that runtime and does not own a distinct
accelerator implementation, so routing the provider through ERE would add an
indirection without replacing any evmz-owned integration.

## Real proof gate

A successful `ziskemu` run proves that the guest completed with the expected
public output; it does not prove that the execution trace satisfies the
prover constraints. Preflight an external-input guest and its framed input
before starting a long proof:

```sh
cargo-zisk-dev verify-constraints \
  --elf /path/to/evmz-guest-zisk.elf \
  --inputs /path/to/stdin.bin \
  --proving-key "${ZISK_HOME}/provingKey"
```

Only a trace with all local and global constraints green is proof-ready:

```sh
cargo-zisk prove \
  --elf /path/to/evmz-guest-zisk.elf \
  --inputs /path/to/stdin.bin \
  --proving-key "${ZISK_HOME}/provingKey" \
  --output /path/to/proof.bin \
  --verify-proof

cargo-zisk verify --proof /path/to/proof.bin
```

The persistent ZisK benchmark host builds with the same pinned revision:

```sh
cargo build --release --manifest-path guest/runtime/Cargo.toml -p evmz-zisk-host
```

The `stateless-ere` guest publishes the raw SSZ `StatelessValidationResult`,
matching `ere-guests` and `zkevm-benchmark-workload`. ZisK pads that result
to its 256-byte public-output region, and the bytes after the SSZ result must
be zero; a guest ELF or proof with a different public-output representation
is not compatible with this contract.
