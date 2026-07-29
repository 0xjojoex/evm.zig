# zkVM guest checks

`guest-zisk` builds the selected payload as a ZisK RV64 ELF. A real
`libziskos_staticlib.a` provider is required:

```sh
zig build guest-zisk -Dguest-payload=basic -Doptimize=ReleaseFast \
  -Dziskos-staticlib=/path/to/libziskos_staticlib.a
```

The `stateless-ere` payload uses the unmetered fixed-buffer allocator by
default. Add `-Dguest-heap-metrics=true` to meter peak heap usage and export
the `evmz_guest_heap_capacity_bytes` and `evmz_guest_heap_peak_used_bytes`
diagnostic symbols. Heap metering is independent of profile tags and changes
the guest execution-step count.

## Host semantic gate

Run the full root suite through the zkVM adapters without building an RV64
guest:

```sh
zig build test -Dprofile=zkvm --summary all
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
