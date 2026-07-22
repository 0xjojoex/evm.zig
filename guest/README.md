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
