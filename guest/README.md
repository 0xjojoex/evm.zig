# zkVM guest checks

`guest-zisk` builds the selected payload as a ZisK RV64 ELF. A real
`libziskos_staticlib.a` provider is required:

```sh
zig build guest-zisk -Dguest-payload=basic -Doptimize=ReleaseFast \
  -Dziskos-staticlib=/path/to/libziskos_staticlib.a
```

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

The default canaries are `basic` and `stateless-smoke`. Override them with one
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

The manual `ZisK execution-step A/B` workflow compares two source refs on a
representative stateless suite. Run it from the candidate branch and leave
`candidate_ref` blank to compare that selected commit against `main`; both refs
can be overridden with pushed branch names or commit hashes for an archived
comparison.

The workflow is intentionally an Ubuntu-only, manually dispatched lab because
it provisions and builds the pinned ZisK toolchain before running the fixture
suite. 

The workflow's intentional pins are:

- ZisK `v1.0.0-alpha` at `4b9f758fabc4955cac20af837019ccc31b803a46`;
- ZisK's Rust toolchain release `zisk-1.0.0`;
- `tests-zkevm@v0.6.2`; and
- Zig `0.16.0` with ReleaseFast guests.

Both upstream pins have breaking changes relative to the archived runner. The
workflow applies the same compatibility surface to both refs: the v0.6.2
Amsterdam SSZ wire adapter and ZisK's matching `zisk-1.0.0` Rust toolchain. 
The selected corpus is in
[`../eest/fixtures/zisk-steps-tests-zkevm-v0.6.2.txt`](../eest/fixtures/zisk-steps-tests-zkevm-v0.6.2.txt).

The workflow reports aggregate and per-fixture execution-step deltas. A step
increase is data, not a failure. Only an incomplete run, emulator crash, or
baseline/candidate public-output mismatch fails the comparison. Upstream
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

### Known-good canary

On 2026-07-26, local `main` at
`85e420686ebdba6e79acbbe2af93d90be8c267fb` produced and independently
verified a real ZisK proof for:

```text
tests-zkevm@v0.6.2/
fixtures/blockchain_tests/for_amsterdam/amsterdam/
eip7708_eth_transfer_logs/eip_mainnet/simple_transfer_mainnet.json
```

The run used Zig `0.16.0`, ZisK `v1.0.0-alpha` at `4b9f758`, the
`zisk-1.0.0` Rust toolchain, and the official `zisk-1.0.0-alpha` proving key.

- Guest execution: 864,643 steps.
- Constraint preflight: 58.66 seconds process wall.
- Proof generation: 1,035.666 seconds; 1,045.62 seconds process wall.
- Standalone proof verification: 40 milliseconds; 0.11 seconds process wall.
- Peak memory reported by the prover: 10.44 GB.
- Framed input SHA-256:
  `96460f5839ddeaf54166350f0d8b2a234f82b1eec560677bdf63e60786ea5093`.
- Guest ELF SHA-256:
  `56fd6cd7919048ddc99737fc2758ccb55bac644c55a8ad7e2da9b1f6707a0533`.
- 381,643-byte proof SHA-256:
  `0c83b8344c18f14c81a745125e106c785998e6c580b531cf7dfe1959d7fad065`.
