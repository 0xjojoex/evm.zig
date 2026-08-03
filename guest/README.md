# zkVM guest checks

`guest-zisk` builds the selected payload as a ZisK RV64 ELF. A real
`libziskos_staticlib.a` provider is required:

```sh
zig build guest-zisk -Dguest-payload=basic -Doptimize=ReleaseFast \
  -Dziskos-staticlib=/path/to/libziskos_staticlib.a
```

Every payload allocates from a fixed buffer whose capacity is chosen at artifact
build time with `-Dguest-heap-bytes=<bytes>`, defaulting to 32 MiB. This applies
to both guest backends and to the native payload tests. The `stateless-ere`
payload uses the unmetered allocator by default; add `-Dguest-heap-metrics=true`
to meter peak heap usage and export the `evmz_guest_heap_capacity_bytes` and
`evmz_guest_heap_peak_used_bytes` diagnostic symbols. Heap metering is
independent of profile tags and changes the guest execution-step count.

ZisK separately defaults to a 48 MiB total RAM envelope, set with
`-Dguest-zisk-ram-bytes=<bytes>`. The envelope holds the guest's data and bss,
then the payload heap, then a 1 MiB stack, and the remainder is ZisKOS heap —
which the linker script asserts is at least 8 MiB. A payload heap therefore has
to stay roughly 9 MiB under the envelope, so the 48 MiB default admits just
under 39 MiB of heap; anything above that needs a larger envelope. Both bounds
are enforced by the linker script, which unlike the build script knows the
guest's actual data and bss sizes.

The ERE RAM top can be matched while retaining Evmz's `0xA0030000` RAM origin
with `-Dguest-zisk-ram-bytes=536674304`; this is a diagnostic envelope, not
required for wire or execution correctness.

These defaults close the pinned `tests-zkevm@v0.6.2` capacity case. They are a
conformance baseline, not a production-mainnet memory claim. Size a deployment
artifact from metered replay of its real witness/block workload and retain an
explicit failure when that artifact's fixed capacity is exceeded.

## SP1 execute-only backend

SP1 v6.3.1 is the second guest backend. It uses the same
`zkvm_accelerators.h` ABI and vendor-static-library shape as ZisK: SP1 owns
`_start`, Zig exports `main`, and no Rust guest wrapper is involved.

Download the released SDK and verify its pinned archive:

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
zig build guest-sp1 -Dguest-payload=basic -Doptimize=ReleaseFast \
  -Dsp1-staticlib=/tmp/zkevm-sdk-v6.3.1/libzkevm.a

zig build guest-sp1-run -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
  -Dsp1-staticlib=/tmp/zkevm-sdk-v6.3.1/libzkevm.a \
  -Dguest-input=/path/to/raw-stateless-input.bin \
  -Dguest-output=/path/to/public-values.bin
```

The host driver is locked to `sp1-core-executor` 6.3.1 and built on demand.
It sends the entire private input as one raw SP1 hint chunk, requires exit code
zero, writes unpadded public values, and reports deterministic instruction
cycles. These are execute-only measurements, not proof cycles or proving time.

SP1's executor accepts RV64IM but not atomic instructions. Because the guest is
single-threaded, `guest/runtime/sp1/atomics.zig` supplies the six 64-bit atomic
libcalls emitted by Zig as ordinary operations. Its exports are strong and
override compiler-rt's weak ones, which matters because compiler-rt implements
them with `@atomicLoad`/`@cmpxchg` and would recurse into the same libcalls on a
target without the A extension. The rest of compiler-rt stays bundled; the guest
needs `memcpy`, `memset`, and `memmove` from it.

The linker script keeps the payload heap as bare symbols rather than an output
section. SP1's ELF loader walks each `PT_LOAD` by `p_memsz` and materializes a
zero word per address past `p_filesz`, so an emitted 16 MiB heap section would
add ~2M entries to the initial memory image on every run.

`zkevm-ere-bench --engine sp1` emits the same ERE-shaped rows as the native
and ZisK engines. Pass `--sp1-host`, `--sp1-elf`, and raw fixture paths. SP1
public output is already raw, unlike ZisK's 256-byte public region.

## Host semantic gate

Run the full root suite through the zkVM adapters without building an RV64
guest:

```sh
zig build test-evmz-zkvm --summary all
```

This test command alone links a host-native implementation of every symbol in
`zkvm_accelerators.h`. Its direct ABI vectors cover hashes, signatures,
RIPEMD-160 padding, modexp, BN254, BLAKE2f, KZG, BLS12-381, status codes, and
compact point shapes. The rest of the root suite then exercises the normal
zkVM adapters against those semantics.

The provider is a correctness test double, not a guest-performance model. It
is not imported by the public module or any guest payload; `guest-zisk` still
requires the real `libziskos_staticlib.a`.

## Source-tree A/B gate

`guest-zisk-ab` builds the same self-contained payload from baseline and
candidate source trees with the same Zig executable, provider, optimization
mode, and emulator. It then:

1. verifies byte-identical public output;
2. requires a nonzero deterministic ZisK step count; and
3. fails if the candidate uses more steps than the baseline.

```sh
zig build guest-zisk-ab -- \
  --baseline-tree /path/to/baseline-worktree \
  --candidate-tree . \
  --ziskemu /path/to/ziskemu \
  --ziskos-staticlib /path/to/libziskos_staticlib.a
```

The default canary is `basic`. Override it with one
or more `--payload` arguments. `--report-only` prints regressions without
failing while exploring a spike. `--global-cache-dir` and
`--system-package-dir` let both trees share an offline Zig package cache.

The reported number is a ZisK execution-step count, not static RV64
instructions, proof-generation cycles, or prover wall time. Treat it as the
guest-side complement to the host RSS and VM-loop benchmarks in
[`bench/`](../bench/README.md). A representation optimization should normally
improve or preserve both surfaces; an explicit product tradeoff should not be
hidden behind a host-only improvement.

## Published cross-guest scoreboard

The complete guest field behind the two-row summary in the root README.
Execute-only totals over the pinned 75-block Amsterdam `tests-zkevm` v0.6.2
manifest (12 JSON files, 52 test objects). Lower is better. evmz uses its
committed release configuration; peers use their published optimized defaults,
including fat LTO and one codegen unit for the Reth and Ethrex SP1 builds. No
peer artifact was rebuilt with evmz-specific flags.

SP1 cycles:

| Guest    | Correct |   Total cycles |  vs leader |
| -------- | ------: | -------------: | ---------: |
| **evmz** |   75/75 | **94,915,078** | **leader** |
| Reth     |   75/75 |    134,914,894 |    +42.14% |
| Ethrex   |   75/75 |    292,260,053 |   +207.92% |

ZisK steps:

| Guest    | Correct |    Total steps |  vs leader |
| -------- | ------: | -------------: | ---------: |
| **Reth** |   75/75 | **54,672,821** | **leader** |
| evmz     |   75/75 |     56,995,060 |     +4.25% |
| Zesu     |   75/75 |     76,314,637 |    +39.58% |
| Ethrex   |   75/75 |    100,659,842 |    +84.11% |

Cycles and steps are backend-specific instruction metrics and must not be
compared across zkVMs. They are not proof cycles or proving time. These measure
the complete stateless guest workload, not the EVM interpreter in isolation.

### Snapshot

- evmz `ee78731dc8b195a0e30460d1c5c09f40121979f6`, Zig `0.16.0`, `ReleaseFast`,
  backend-specific RV64 target features with linker relaxation, frame pointers
  omitted, fully relaxed external SP1 and ZisK provider archives, stripped ELF,
  `.medium` code model.
- Workload: Eth Act `zkevm-benchmark-workload`
  `35fa24ebf007edd4c9d65bdc41b25cb5fd726a80`; ERE
  `58ca85beaee2fa8acd31dbf33b90bb765aac9010`.
- Reth and Ethrex guests: `ere-guests`
  `a52609d4553405ab46d2dbda60dffd59b47e2082`. Zilkworm: official
  `zilkworm-stateless` v0.2.5, commit `bd2638c`.
- Host: Linux 6.8.0-110-generic, x86_64, 4-vCPU AMD EPYC Genoa, 7.6 GiB RAM.
- Fixture manifest SHA-256
  `fdd5f0e59e0343df0a569fcb04e1aa49ea4e7537b455236686573584da263e8b`.
- Each of the eight backend/guest combinations ran twice. Pass 2 changed no
  cycle or step count, correctness result, or public output.

The integration patch that drives the guests is preserved at
[`0xjojoex/zkevm-benchmark-workload@a7e2203a`](https://github.com/0xjojoex/zkevm-benchmark-workload/tree/a7e2203a2316d9a44254a8ebfe3f1d51c1baa744).

## Pinned stateless fixture report

The `ZisK execution steps` workflow measures one ref on a representative
stateless suite and compares it against the rows archived by the last
successful `main` run. Step counts are deterministic and host-independent, so a
stored baseline is as good as a same-runner rebuild — the workflow builds one
guest instead of two. It runs on every push to `main`, which refreshes the
stored baseline, and on manual dispatch from any branch. `baseline_run_id`
overrides which run is used as the reference point.

Baselines are carried by the `zisk-step-results` artifact (90-day retention).
When no successful `main` run is reachable, the workflow reports absolute step
counts instead of failing.

The workflow is intentionally Ubuntu-only because it provisions and builds the
pinned ZisK toolchain before running the fixture suite.

The workflow's intentional pins are:

- ZisK `v1.0.0-alpha` at `4b9f758fabc4955cac20af837019ccc31b803a46`;
- ZisK's Rust toolchain release `zisk-1.0.0`;
- `tests-zkevm@v0.6.2`; and
- Zig `0.16.0` with ReleaseFast guests.

Both upstream pins have breaking changes relative to the archived runner. The
compatibility surface is the v0.6.2 Amsterdam SSZ wire adapter and ZisK's
matching `zisk-1.0.0` Rust toolchain. Because the baseline is a stored artifact
rather than a rebuild, a change to either pin invalidates comparison against
older runs; land it on `main` first so the next baseline is measured under the
new pins. The selected corpus is in
[`../eest/fixtures/zisk-steps-tests-zkevm-v0.6.2.txt`](../eest/fixtures/zisk-steps-tests-zkevm-v0.6.2.txt).

The workflow reports aggregate and per-fixture execution-step deltas. A step
increase is data, not a failure. Only an incomplete run, emulator crash, or
baseline/current public-output mismatch fails the comparison. Upstream
expected-output matches are shown separately because existing Amsterdam
semantic gaps are outside this performance comparison. No proof generation is
part of this workflow.

## Real proof gate

A successful `ziskemu` run proves that the guest completed with the expected
public output; it does not prove that the execution trace satisfies the prover
constraints. Preflight an external-input guest and its framed input before
starting a long proof:

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

`zkevm-ere-bench --engine zisk` writes the required framed input as
`stdin.bin` below its `--zisk-work-dir`. Keep emulator execution steps, prover
wall time, and standalone verification time as separate measurements.

The `stateless-ere` guest publishes the raw SSZ `StatelessValidationResult`,
matching `ere-guests` and `zkevm-benchmark-workload`. ZisK pads that result to
its 256-byte public-output region; the bytes after the SSZ result must be zero.
Any guest ELF or proof produced with a different public-output representation
is not compatible with this contract.
