# evmz EEST sidecar

This package owns the Ethereum Execution Spec Tests runners for `evmz`.

```sh
scripts/fetch-eest-fixtures.sh
zig build eest-scope
zig build eest
zig build eest -- ../.eest/fixtures/tests-glamsterdam-devnet-v6.1.0/fixtures/state_tests/path/to/test.json
zig build eest-classify
zig build eest-tx
```

The default state-test corpus comes from `eest.lock`, currently
`tests-glamsterdam-devnet@v6.1.0` from `ethereum/execution-specs` for Amsterdam
work. Bare `zig build eest` resolves `eest.lock` `dest` and runs
`fixtures/state_tests`.

Benchmark fixtures are a separate EEST release track:

```sh
scripts/fetch-eest-benchmarks.sh
zig build bench -- ../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures/blockchain_tests/benchmark/compute
zig build bench -- --list --match opcode_MSTORE --match offset_0 ../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures/blockchain_tests/benchmark/compute/instruction/memory/memory_access.json
zig build bench -- --match opcode_MSTORE --match offset_0 --max-tests 1 ../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures/blockchain_tests/benchmark/compute/instruction/memory/memory_access.json
zig build bench -- --engine evmone ../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures/blockchain_tests/benchmark/compute/instruction/storage/tload.json
```

`zig build bench` defaults the benchmark executable to `ReleaseFast`. Use
`-Dbench-optimize=ReleaseSafe` for checked benchmark runs. Use repeated
`--match` filters to isolate fixture/test names; filters are ANDed. `--list`
prints matching fixtures without executing them, and `--max-tests N` caps the
matched fixtures globally across all paths.
