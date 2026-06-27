# evm.zig

`evm.zig` is an embeddable Ethereum Virtual Machine written in Zig. It is a VM
library first: small enough to inspect, strict enough to run Ethereum Execution
Spec Tests, and fast enough to benchmark against evmone and revm.

Current state: the VM is functionally close to complete for the downloaded EEST
state-test corpus, with performance in parity territory against the comparison
engines used by the local benchmark lab.

## Status

| Area           | State                                                                                                                                                                                                                                                    |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Correctness    | Latest full state-test run: `44,039/44,039` vectors passed across `2,681` files, with `0` failures, skips, timeouts, or crashes.                                                                                                                         |
| Fork coverage  | Fork rules are modeled through `osaka` (`Spec.latest`). The passing EEST set includes Frontier through Osaka buckets.                                                                                                                                    |
| Performance    | Portable-release reports compare evmz with evmone baseline, evmone advanced, and revm. Realistic VM-loop fixtures are close to evmone-baseline, broadly comparable to evmone-advanced, and generally ahead of the revm interpreter path used by the lab. |
| Public surface | Zig API, executor/state layer, EVMC-compatible C entrypoint, EEST runner, benchmark sidecar, and local report generator.                                                                                                                                 |

This is not an execution client. Networking, block sync, trie/root validation,
receipts, and production database integration are outside the current library
scope.

## What Is Included

- `Interpreter`: opcode execution, gas accounting, memory, stack, control flow,
  storage, calls, logs, and system instructions.
- `Executor`: transaction-oriented execution over a state backend plus overlay.
- `Host`: native Zig host interface and EVMC bridge.
- Fork-aware `Spec` handling through Osaka.
- Ethereum transaction, transaction-envelope, RLP, address, and `uint256`
  helpers.
- Native-backed precompiles for the supported fork set.
- EVMC-compatible C ABI via `evmc_create_evmz`.
- EEST sidecar for state-test and benchmark fixtures.
- Benchmark lab for VM-loop, opcode-kernel, host-boundary, evmone, and revm
  comparisons.

## Quick Start

Build the library and C artifacts:

```sh
zig build -Doptimize=ReleaseFast
```

Run unit tests:

```sh
zig build test
```

Run the basic Zig example:

```sh
zig build example
```

Use the package from Zig code:

```zig
const evmz = @import("evmz");

var executor = evmz.Executor.init(allocator, .{
    .spec = .cancun,
});
defer executor.deinit();

try executor.beginTransaction(tx_context, sender, recipient);
```

See `examples/basic.zig` for a complete in-memory call transaction.

## Correctness

The EEST sidecar owns fixture fetching, parsing, classification, and execution:

```sh
cd eest
scripts/fetch-eest-fixtures.sh
zig build eest-scope
zig build eest-classify
zig build eest -- ../.eest/fixtures/v5.4.0/fixtures/state_tests/path/to/test.json
```

Root delegates are available too:

```sh
zig build eest-test
zig build eest-scope
zig build eest-classify
```

The latest full local summary reports:

```text
files_seen=2681 completed=2681 timeouts=0 crashes=0
vectors=44039 passed=44039 failed=0 skipped=0 unchecked=0
```

That result is the main correctness signal for the current implementation. The
EEST benchmark runner also consumes decoded `blockchain_tests` benchmark
fixtures, but raw engine payloads, trie/root validation, receipts, and benchmark
genesis/stateful setup remain later-phase work.

## Performance

Benchmarking lives in `bench/` and writes ignored artifacts under `output/`.
The default comparison lane is portable release: Zig `ReleaseFast`, evmone
compiled into the Zig bench binary, and revm `cargo --release`, without native
CPU flags.

Generate a comparison report:

```sh
zig build bench-report -- --out-dir ../output/bench-report
```

Useful direct comparisons:

```sh
zig build bench-vm-loop -- --fixture fixtures/vm-loop/erc20-transfer --summary
zig build bench-vm-loop -- --engine evmone --fixture fixtures/vm-loop/erc20-transfer --summary
zig build bench-revm-vm-loop -- --fixture fixtures/vm-loop/erc20-transfer --summary
zig build bench-kernel -- --engine evmz --engine evmone-baseline --engine evmone --case add
zig build bench-revm-kernel -- --case add
```

Current portable-release snapshot:

Speed relative to evmz for the same workload group: `evmz = 1.00x`; higher is
faster.

| Workload group    |    evmz | evmone-base | evmone-adv | revm-int |
| ----------------- | ------: | ----------: | ---------: | -------: |
| ERC20 mint        | `1.00x` |    `~1.22x` |   `~0.85x` | `~0.50x` |
| ERC20 transfer    | `1.00x` |    `~1.12x` |   `~0.93x` | `~0.77x` |
| Arithmetic loop   | `1.00x` |     `~3.1x` |    `~1.0x` | `~0.63x` |
| Memory store loop | `1.00x` |     `~2.2x` |   `~0.91x` | `~0.50x` |
| Keccak loop       | `1.00x` |     `~2.0x` |    `~1.1x` | `~0.53x` |
| Taken jumps       | `1.00x` |     `~3.0x` |   `~0.59x` |  `~1.4x` |

The VM-loop rows measure deployed runtime calls. Deployment, fixture loading,
and report generation are outside the timed section. evmz times
`Interpreter.execute()`. evmone rows time EVMC `execute()` on a fixture-scoped
VM with the same fixture protocol. revm rows use the lab's low-level interpreter
runner, so they are useful context but not a byte-for-byte identical execution
boundary.

See `bench/README.md` for benchmark commands and report format. Local generated
reports stay under ignored `output/`.

## Layout

| Path        | Purpose                                                                   |
| ----------- | ------------------------------------------------------------------------- |
| `src/`      | Core VM, executor, state, host, precompiles, RLP, transaction, and C API. |
| `include/`  | Public C header for the EVMC-compatible entrypoint.                       |
| `examples/` | Small runnable examples.                                                  |
| `eest/`     | Ethereum Execution Spec Tests sidecar.                                    |
| `bench/`    | Micro, VM-loop, kernel, host-boundary, evmone, and revm benchmark lab.    |
| `output/`   | Ignored local benchmark reports and checkpoints.                          |
| `.eest/`    | Ignored downloaded fixtures and local EEST summaries.                     |

## Current Gaps

- Full client duties are out of scope: networking, consensus, block sync,
  persistent state, receipts, and trie/root validation.
- The EEST raw engine payload path is intentionally later-phase.
- Performance work is now mostly interpreter-shape work: predecode, analyzed
  bytecode, or basic-block execution.
- Public API polish is still ongoing; the Zig API is the primary surface, with
  the C ABI available for EVMC-style embedding.

## License

evm.zig source is licensed under MIT.

This repository also builds against third-party components that retain their own
licenses. In particular, evmone/EVMC precompile code is licensed under
Apache-2.0. Binary and source distributions should include the relevant
third-party license notices.
