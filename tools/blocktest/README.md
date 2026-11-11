# evmz blocktest

Imports RLP-encoded signed blocks from an Ethereum blockchain fixture JSON,
executes them through `block.Stf`, and prints per-block acceptance/rejection and
the final post-state root (`tools/blocktest/root.zig` is shared by the CLI and EEST).

Fixtures from Paris on run, including EEST's timestamp transition networks
such as `AmsterdamToBogotaAtTime15k`: each block runs under the fork its
timestamp selects, with that fork's blob schedule entry.

```sh
zig build blocktest -- --trace-summary tools/blocktest/testdata/chain.json
zig build blocktest -- --trace --run rollback_then_children tools/blocktest/testdata/chain.json
```

Or build `zig-out/bin/evmz` once with `zig build cli-build` and run
`zig-out/bin/evmz blocktest [options] <blockchain.json>`.

| Flag | Effect |
| --- | --- |
| `--run <EXACT_ID>` | Run one named test from a multi-test fixture file (required if the file has >1 test) |
| `--trace` | Emit per-opcode EIP-3155 JSON lines and summary for each block |
| `--trace-summary` | Emit only the EIP-3155 summary line for each block |

Run the tool's unit tests with `zig build blocktest-test`.
