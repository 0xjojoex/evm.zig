# zkVM guests

The stateless validator compiles to an RV64 ELF for ZisK and SP1. Both
backends share the `zkvm_accelerators.h` ABI and the same shape: the vendor
static library owns `_start`, Zig exports `main`, and no Rust guest wrapper is
involved.

## Building

`guest-zisk` builds the selected payload as a ZisK RV64 ELF. A real
`libziskos_staticlib.a` provider is required:

```sh
zig build guest-zisk -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dstateless-schema=0x1501 \
  -Dziskos-staticlib=/path/to/libziskos_staticlib.a
```

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

The `Guest benchmark` workflow is the single execute-only guest performance
surface; ZisK is currently the only enabled backend. Pull requests and pushes
to `main` replay the immutable 100-block `glamsterdam-devnet-7` snapshot in
[`../eest/fixtures/devnet-glamsterdam-7-pinned.json`](../eest/fixtures/devnet-glamsterdam-7-pinned.json),
and a nightly run resolves the latest ten complete R2 batches. Correctness is
the gate — every archive digest, execution, and public output must match —
while cycle changes never fail the workflow. When
[`../eest/fixtures/guest-release-baseline.json`](../eest/fixtures/guest-release-baseline.json)
names immutable release ELFs, the runner also reports aggregate and per-block
deltas against them. ZisK steps and SP1 cycles stay separate metrics, and
emulator execution duration is never treated as proving time.

`zig build zkevm -- --executor zisk|sp1` runs the same ERE-shaped
measurements locally; pass `--zisk-host`/`--zisk-elf` or
`--sp1-host`/`--sp1-elf` and fixture paths.

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
