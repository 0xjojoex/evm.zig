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
compatibility token, and the verification key identifies the exact bytes. See
[the release policy](https://github.com/0xjojoex/evm.zig/blob/main/RELEASING.md).

## Building

`guest-zisk` builds the selected payload as a ZisK RV64 ELF. A real
`libziskos_staticlib.a` provider is required:

```sh
zig build guest-zisk -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dstateless-schema=0x1501 \
  -Dziskos-staticlib=/path/to/libziskos_staticlib.a
```

Build the ZisK provider with
`CARGO_TARGET_RISCV64IMA_ZISK_ZKVM_ELF_RUSTFLAGS="-C target-feature=+unaligned-scalar-mem"`.
The pinned CI build uses this target policy. A provider built without it produces
a different guest ELF and verification key.

For SP1 (v6.3.1), download the released SDK and verify its pinned archive:

```sh
curl -fL \
  https://github.com/succinctlabs/sp1/releases/download/v6.3.1/zkevm-sdk-v6.3.1.tar.gz \
  -o /tmp/zkevm-sdk-v6.3.1.tar.gz
echo "ef9124009aa88a5039f003bda51fc5210888cc6aa878320aac04666a3389bfb8  /tmp/zkevm-sdk-v6.3.1.tar.gz" \
  | shasum -a 256 -c -
tar -xzf /tmp/zkevm-sdk-v6.3.1.tar.gz -C /tmp
```

Build or execute a payload with the released `libzkevm.a`:

```sh
zig build guest-sp1 -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dsp1-staticlib=/tmp/zkevm-sdk-v6.3.1/libzkevm.a

zig build guest-sp1-run -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dsp1-staticlib=/tmp/zkevm-sdk-v6.3.1/libzkevm.a \
  -Dguest-input=/path/to/raw-stateless-input.bin \
  -Dguest-output=/path/to/public-values.bin
```

The SP1 host driver is locked to `sp1-core-executor` 6.3.1 and built on
demand. It reports deterministic execute-only instruction cycles — not proof
cycles or proving time.

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

The build links OpenVM's official startup and ERE v0.15.0's
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

Every payload allocates from a fixed-capacity heap chosen at build time with
`-Dguest-heap-bytes=<bytes>`, defaulting to 480 MiB. Add
`-Dguest-heap-metrics=true` to meter peak heap usage; metering changes the
guest execution-step count. ZisK additionally takes a total RAM envelope with
`-Dguest-zisk-ram-bytes=<bytes>`, defaulting to end at ZisK's declared RAM
top. The linker scripts enforce both bounds, and capacity is free: heap and
envelope size change neither the ELF nor the step count.

These defaults are a conformance envelope, not a production-mainnet memory
claim. Size a deployment artifact from metered replay of its real
witness/block workload, and retain an explicit failure when that fixed
capacity is exceeded.

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
Automatic and release-qualified runs remain ZisK-only. A manual dispatch can
run OpenVM against the same `tests-zkevm@latest` corpus and retain ERE
`BenchmarkRun` rows with retired instructions and trace-cell cost. Correctness
still gates the run: every public output must match. Metrics from different
zkVMs are kept separate, and emulator execution duration is not proving time.

Reports are absolute: the workflow measures the candidate ELF and does not
compare against a release. The existing `zkevm` command writes the ERE rows,
aggregated report, and one `evidence.json`; there is no separate reporting
script or stored release baseline.

A strict `tests-zkevm` dispatch produces the only artifact eligible for guest
release. `Guest release` accepts that run id, verifies the evidence, tag, source
commit, and ELF hash, then promotes the tested bytes without rebuilding them.

`zig build zkevm -- --executor zisk|sp1|openvm` runs the same ERE-shaped
measurements locally; pass `--zisk-host`/`--zisk-elf` or
`--sp1-host`/`--sp1-elf` and fixture paths. OpenVM uses `--openvm-host`,
`--openvm-config`, and `--openvm-elf`; use `--jobs 1` so the host converts the
ELF only once. `--evidence-dir` enables the release evidence path used by CI;
ZisK remains the only release evidence backend.

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
cargo build --release --manifest-path guest/runtime/zisk/host/Cargo.toml
```

The `stateless-ere` guest publishes the raw SSZ `StatelessValidationResult`,
matching `ere-guests` and `zkevm-benchmark-workload`. ZisK pads that result
to its 256-byte public-output region, and the bytes after the SSZ result must
be zero; a guest ELF or proof with a different public-output representation
is not compatible with this contract.
