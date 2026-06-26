# evmz EEST sidecar

This package owns the Ethereum Execution Spec Tests runners for `evmz`.

```sh
scripts/fetch-eest-fixtures.sh
zig build eest-scope
zig build eest -- ../.eest/fixtures/v5.4.0/fixtures/state_tests/path/to/test.json
zig build eest-classify
zig build eest-tx
```

Benchmark fixtures are a separate EEST release track:

```sh
scripts/fetch-eest-benchmarks.sh
zig build bench -- ../.eest/benchmarks/benchmark-v0.0.7/fixtures/blockchain_tests/benchmark/compute
zig build bench -- --list --match opcode_MSTORE --match offset_0 ../.eest/benchmarks/benchmark-v0.0.7/fixtures/blockchain_tests/benchmark/compute/instruction/memory/memory_access.json
zig build bench -- --match opcode_MSTORE --match offset_0 --max-tests 1 ../.eest/benchmarks/benchmark-v0.0.7/fixtures/blockchain_tests/benchmark/compute/instruction/memory/memory_access.json
zig build bench -- --engine evmone ../.eest/benchmarks/benchmark-v0.0.7/fixtures/blockchain_tests/benchmark/compute/instruction/storage/tload.json
```

`zig build bench` defaults the benchmark executable to `ReleaseFast`. Use
`-Dbench-optimize=ReleaseSafe` for checked benchmark runs. Use repeated
`--match` filters to isolate fixture/test names; filters are ANDed. `--list`
prints matching fixtures without executing them, and `--max-tests N` caps the
matched fixtures globally across all paths.
