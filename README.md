# evm.zig

`evm.zig` is an embeddable Ethereum Virtual Machine written in Zig. It is a VM
library first: small enough to inspect, strict enough to run Ethereum Execution
Spec Tests, and fast enough to benchmark against evmone and revm.

Current state: the VM has broad fork and opcode coverage, and the locked EEST
state-test corpus passes end to end. Benchmark surfaces remain split between
VM-core comparisons and transaction-facade diagnostics.

## Status

| Area           | State                                                                                                                                                                                                                                                                              |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Correctness    | Locked EEST v5.4.0 state tests pass `44,039` vectors: `44,039` passed, `0` failed, `0` skipped, `0` unchecked.                                                                                                                                                                      |
| Fork coverage  | Fork rules are modeled through `osaka` (`Spec.latest`). EEST fixtures load across Frontier through Osaka buckets.                                                                                                                                                                  |
| Performance    | Portable-release VM-core reports compare direct evmz interpreter execution with standalone evmone baseline/advanced and revm interpreter runners. Current results are mixed: evmz is strongest on `SSTORE` and ERC20 mock-host calls, but trails evmone baseline on tight dispatch, memory, log, and `SLOAD` fixtures. |
| Public surface | Zig API, VM/state layer, EVMC-compatible C entrypoint, EEST runner, benchmark sidecar, and local report generator.                                                                                                                                                                 |

This is not an execution client. Networking, block sync, trie/root validation,
receipts, and production database integration are outside the current library
scope.

## What Is Included

- `Interpreter`: opcode execution, gas accounting, memory, stack, control flow,
  storage, calls, logs, and system instructions.
- `Vm`: public runtime state-transition facade over a `StateReader` plus
  overlay, transaction validation, gas purchase, and commit/discard.
- `Host`: native Zig host interface and EVMC bridge.
- `executor`: advanced execution core used by diagnostics, benchmark sidecars,
  and lower-level integrations.
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
zig build test -- <filter>
```

Run the basic Zig example:

```sh
zig build example
```

Use the package from Zig code:

```zig
const evmz = @import("evmz");

const sender = evmz.addr(0xaaaa);
const recipient = evmz.addr(0xbbbb);
const gas_limit: u64 = 100_000;

var memory = evmz.state.MemoryStore.init(allocator);
defer memory.deinit();

var vm = evmz.Vm.init(allocator, .{
    .spec = .latest,
    .state_reader = memory.reader(),
    .env = .{ .gas_limit = gas_limit },
});
defer vm.deinit();

const result = try vm.transact(.{
    .sender = sender,
    .to = recipient,
    .gas_limit = gas_limit,
});
```

See `examples/basic.zig` for a complete in-memory call transaction.

## Correctness

The EEST sidecar owns fixture fetching, parsing, classification, and execution:

```sh
cd eest
scripts/fetch-eest-fixtures.sh
zig build eest-scope
zig build eest-classify
zig build eest
zig build eest -- ../.eest/fixtures/v5.4.0/fixtures/state_tests/path/to/test.json
```

The default state-test fetch stays on the latest supported stable Osaka snapshot.
Moving test-release and benchmark fixture tags now live in
`ethereum/execution-specs`. Bare `zig build eest` resolves `eest.lock`
`dest` and runs `fixtures/state_tests`.

Root delegates are available too:

```sh
zig build eest-test
zig build eest-scope
zig build eest-classify
```

The latest locked state-test run reports:

```text
../.eest/fixtures/v5.4.0/fixtures/state_tests:
fixtures=44039 vectors=44039 passed=44039 failed=0 skipped=0 unchecked=0
```

This is the main correctness signal for the current implementation. The state
runner checks transaction nonce, fixture chain/blob config, and post-state
account balance, nonce, code, and storage. It rejects unknown keys in supported
fixture shapes.

The EEST benchmark runner also consumes decoded `blockchain_tests` benchmark
fixtures, but raw engine payloads, trie/root validation, receipts, and benchmark
genesis/stateful setup remain later-phase work.

## Performance

Benchmarking lives in `bench/` and writes ignored artifacts under `output/` or
`bench/zig-out/`, depending on the runner. The default VM-core comparison lane
is portable release: Zig/C++ runners use `ReleaseFast`, and revm uses
`cargo --release`, without native CPU flags. The transaction-facade comparison
is intentionally separate and not part of the default VM-core scoreboard yet.

Generate the VM-core comparison or the broader benchmark report:

```sh
zig build bench-compare -- --num-runs 1000
zig build bench-report -- --out-dir ../output/bench-report
```

Useful direct comparisons:

```sh
zig build bench-vm-loop -- --fixture fixtures/vm-loop/erc20-transfer --summary
zig build bench-evmone-vm-loop -- --fixture fixtures/vm-loop/erc20-transfer --summary
zig build bench-revm-vm-loop -- --fixture fixtures/vm-loop/erc20-transfer --summary
zig build bench-kernel -- --engine evmz --engine evmone-baseline --engine evmone --case add
zig build bench-revm-kernel -- --case add
```

Current portable-release VM-core snapshot:

Median milliseconds from `zig build bench-compare -- --num-runs 1000`. Lower is
faster.

| VM-loop fixture     |    evmz | evmone-base | evmone-adv | revm-int |
| ------------------- | ------: | ----------: | ---------: | -------: |
| Arithmetic loop     | `0.290` |     `0.105` |    `0.338` |  `0.503` |
| Memory store loop   | `0.229` |     `0.104` |    `0.257` |  `0.431` |
| Keccak loop         | `3.674` |     `3.744` |    `3.718` |  `3.009` |
| Ten-thousand hash   | `1.725` |     `0.927` |    `1.703` |  `2.276` |
| Storage SLOAD loop  | `0.131` |     `0.075` |    `0.104` |  `0.116` |
| Storage SSTORE loop | `0.362` |     `1.295` |    `1.325` |  `1.169` |
| LOG0 loop           | `0.100` |     `0.038` |    `0.084` |  `0.131` |
| ERC20 mint          | `3.350` |     `4.571` |    `5.432` |  `4.063` |
| ERC20 transfer      | `6.142` |     `7.290` |    `8.311` |  `6.799` |

The VM-loop rows measure deployed runtime calls. Deployment, fixture loading,
bytecode analysis/preparation, and frame/interpreter setup are outside the
timed section. evmz times direct `Interpreter.execute()`. evmone rows use the
standalone C++ analyzed baseline/advanced runners. revm rows use the lab's
low-level `Interpreter::run_plain()` sidecar. Mock-host fixtures still include
each engine's host boundary and mock-host implementation, so storage, log, and
ERC20 rows are not pure-opcode measurements.

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
- The EEST raw engine payload and benchmark/stateful setup paths are
  intentionally later-phase.
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
