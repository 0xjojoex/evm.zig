# zkVM guest checks

`guest-zisk` builds the selected payload as a ZisK RV64 ELF. A real
`libziskos_staticlib.a` provider is required:

```sh
zig build guest-zisk -Dguest-payload=basic -Doptimize=ReleaseFast \
  -Dziskos-staticlib=/path/to/libziskos_staticlib.a
```

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
