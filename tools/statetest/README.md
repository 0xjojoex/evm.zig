# evmz statetest

Executes a General State Test JSON vector and writes the observed `stateRoot`,
`logsHash`, gas usage, and optional EIP-3155 opcode traces. Compatible with
`goevmlab` and EEST (`tools/statetest/root.zig` is shared by the CLI and EEST).

```sh
zig build statetest -Doptimize=safe -- --trace case.json
zig build statetest -Doptimize=safe -- --trace-summary case.json
zig build statetest -Doptimize=safe -- --profile case.json
```

Or build `zig-out/bin/evmz` once with `zig build cli-build -Doptimize=safe` and
run `zig-out/bin/evmz statetest [options] <single-vector.json>`.

| Flag | Effect |
| --- | --- |
| `--trace` | Emit per-opcode EIP-3155 JSON lines and final summary before the result array |
| `--trace-summary` | Emit only the final EIP-3155 summary line before the result array |
| `--profile` | Write phase timing breakdown (`statetest_profile_ns`) as JSON to stderr |

Run the tool's unit tests with `zig build statetest-test -Doptimize=safe`.
