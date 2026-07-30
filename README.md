# evmz

**A fast, composable Ethereum execution engine in Zig — from native execution to
the same block state transition function inside SP1 and ZisK.**

In evmz, one exact Ethereum specification is a compile-time value. Its dispatch
table, gas schedule, precompiles, transaction rules, and block hooks are
resolved into one concrete VM, without runtime fork selection inside the
generated engine.

## Highlights

- **Composable** — patch protocol parameters, replace instruction or precompile
  tables, or bind custom transaction and block programs.
- **Fast natively** — ahead of the revm interpreter in every row of both VM-loop
  snapshots. Against evmone's baseline, the workload-shaped wins range from
  1.7–2.9× on Snailtracer, 1.1–2.0× on ERC20 mint, and 1.4–4.4× on the SSTORE
  loop.
- **Stateless and guest-ready** — run the same witness-backed block validator
  natively or as an RV64 guest on SP1 and ZisK. On the pinned 75-block [Eth Act
  workload](https://github.com/eth-act/zkevm-benchmark-workload), evmz leads SP1
  at 94.9M cycles — 29.7% under Reth's guest — and sits second on ZisK within
  4.3%.
- **Tested** — `67,066/67,066` EEST vectors pass for Glamsterdam devnet-7.

## Status

evmz is pre-release. The version is `0.0.0`, the public API may change between
commits, and the project has not been audited.

Implemented:

- Ethereum execution through Glamsterdam devnet-7, whose execution-layer fork is
  Amsterdam
- Stateless block validation from execution witnesses
- Native, SP1, and ZisK execution of the stateless validator
- EVMC-compatible static and shared libraries

Experimental:

- Block-access-list validation and BAL-driven parallel verification
- Deeper transaction and block programmability
- A native evmz C API

## Install

Requires Zig `0.16.0+`.

```sh
zig fetch --save git+https://github.com/0xjojoex/evm.zig
```

```zig
// build.zig
const evmz = b.dependency("evmz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("evmz", evmz.module("evmz"));
```

This follows `main`; pin a commit for reproducible builds.

## Quick start

```zig
const std = @import("std");
const evmz = @import("evmz");

// Use your own StateReader in production.
var memory = evmz.state.MemoryStore.init(allocator);
defer memory.deinit();

var executor = evmz.Evm.Executor.init(allocator, .{
    .state_reader = memory.reader(),
});
defer executor.deinit();

var vm = evmz.Evm.init(&executor);
const execution = switch (try vm.transact(.{
    .env = .{ .gas_limit = 100_000 },
    .tx = .{
        .sender = evmz.addr(0xaaaa),
        .to = evmz.addr(0xbbbb),
        .gas_limit = 100_000,
    },
})) {
    .executed => |value| value,
    .rejected => return error.TransactionRejected,
};
defer execution.discardIfCurrent();

const result = execution.result();
std.debug.print("status: {any}, gas: {}\n", .{
    result.status,
    result.gas.used,
});

// Accept the provisional branch. Without this, the deferred discard rolls back.
execution.retain();
```

`retain()` accepts the execution into the executor's pending branch. Block-level
code can consume `executor.acceptedChanges()` and persist it. See
[`examples/basic.zig`](examples/basic.zig) for runnable transaction execution
and provisional storage-change inspection.

## Execution layers

evmz exposes the execution stack as separate reusable surfaces:

| Surface | Responsibility |
| --- | --- |
| Interpreter | EVM bytecode and call-frame execution |
| Transaction program | Envelope validation, fees, nonce, execution, and settlement |
| Block program | Ordered transaction execution and block-level rules |
| Stateless validator | Witness validation and post-state and receipts roots |
| Guest | The stateless validator compiled for SP1 or ZisK |

## Exact specifications

`Evm` is the latest exact Ethereum VM. Bind another specification at compile
time:

```zig
const LatestEvm = evmz.Evm;
const CancunEvm = evmz.Vm(evmz.eth.cancun);
```

Extend the exact base you mean and compile it into a concrete VM:

```zig
const my_cancun = evmz.eth.cancun.extend(.{
    .transaction = .{
        .max_initcode_size = 0x10000,
    },
    .settlement = .{
        .gas_refund_cap_divisor = 4,
    },
});
const MyEvm = evmz.Vm(my_cancun);
```

`Spec.extend` patches parameters and semantic functions. Complete instruction,
precompile, transaction, or block bindings can also be replaced. See
[`examples/custom_fork/`](examples/custom_fork/) and
[`examples/op_deposit.zig`](examples/op_deposit.zig).

## Stateless validation and zkVM guests

`evmz.stateless` validates a block from an execution witness and returns its
post-state and receipts roots:

```zig
const Validator = evmz.stateless.Exact(.amsterdam);
const result = try Validator.validate(allocator, input);
```

The same validator is compiled natively and as an RV64 ELF under `guest/`.
SP1 and ZisK share one accelerator ABI while retaining backend-specific
runtimes and host drivers.

See [`guest/README.md`](guest/README.md) for backend setup, semantic and
source-tree gates, input/output contracts, and proof-readiness checks.

## Performance

### Stateless guest execution

Execute-only totals over the pinned 75-block Amsterdam
[`tests-zkevm` workload](https://github.com/eth-act/zkevm-benchmark-workload).
All shown guests matched the expected public output for `75/75` fixtures.

| Backend metric | evmz | Reth | evmz vs Reth |
| --- | ---: | ---: | ---: |
| SP1 cycles | **94,915,078** | 134,914,894 | **−29.65%** |
| ZisK steps | 56,995,060 | **54,672,821** | +4.25% |

Cycles and steps are backend-specific instruction metrics and must not be
compared across zkVMs. They are not proof cycles or proving time.

Snapshot: evmz `ee78731d`; Reth `ere-guests@a52609d`. The pinned
[benchmark integration](https://github.com/0xjojoex/zkevm-benchmark-workload/tree/a7e2203a2316d9a44254a8ebfe3f1d51c1baa744)
contains the workload and runner. The complete guest field, win/loss profile, and
correctness gates are in
[`guest/README.md`](guest/README.md#published-cross-guest-scoreboard).

### Native interpreter

Representative Apple M1 Max results from the fixed-Osaka `ReleaseFast`
snapshot; lower is better:

| Fixture | evmz | evmone-base | revm-int |
| --- | ---: | ---: | ---: |
| Arithmetic loop | 0.119 ms | **0.099 ms** | 0.489 ms |
| Storage SSTORE loop | **0.196 ms** | 0.866 ms | 0.858 ms |
| ERC20 transfer | **3.859 ms** | 6.183 ms | 6.088 ms |
| Snailtracer | **20.495 ms** | 59.606 ms | 37.704 ms |

Both full snapshots, fixtures, methodology, and reproduction commands are in
[`bench/README.md`](bench/README.md#published-snapshots).

<details>
<summary>The evmz approach</summary>

evmz bets on compile-time protocol specialization. One complete specification
(gas schedules, opcode availability, dispatch targets, transaction rules, and
block hooks) is a comptime value. The 256-entry dispatch table, static gas
constants, and fork gates are resolved at build time and baked into the binary.
There is no runtime revision state inside the generated VM.

Execution is two-tier. Prepared tail dispatch carries machine state
(instruction pointer, stack pointer, gas) in registers and has dedicated
handlers for selected common operations, including storage. Fork-gated ops,
custom dispatch overrides, CALL/CREATE, and tracing spill to the generic
handler set that operates on the full CallFrame. Generic protocol hot/cold tier
metadata is a separate dispatch decision from prepared-tail handler selection.

Around the interpreter sits a zero-alloc, pooled executor: frames, stacks,
messages, and IO buffers live in preallocated slots (optionally hard-bounded for
embedded/zkVM targets), and the state journal is cheap enough that the full
executor benches within noise of the raw interpreter.

The same property pays off twice. Natively it removes per-instruction fork
checks; in a zkVM guest it removes the code and memory a runtime-configurable
VM would carry into the proof.

</details>

## EVMC

The standalone `pkg/evmc` package builds static and shared `libevmz-evmc`
artifacts exporting `evmc_create_evmz`:

```sh
zig build evmc -Doptimize=ReleaseFast
zig build evmc-test
zig build evmc-example -Doptimize=ReleaseFast
```

The root `include/evmz/evmz.h` path is reserved for a future native evmz C API.

## Packages

Standalone Zig libraries under `pkg/` can be fetched independently:

- [`pkg/rlp`](pkg/rlp) — strict RLP encoding and decoding
- [`pkg/mpt`](pkg/mpt) — Merkle Patricia Trie proofs and sparse updates
- [`pkg/ssz`](pkg/ssz) — comptime-typed SSZ encoding and decoding

## Scope

evmz is an execution engine, not a client. It includes the EVM, Ethereum block
state transition, stateless witness validation, and the trie work needed to
produce post-state and receipts roots.

Networking, block sync, consensus-layer fork choice, RPC, persistent storage,
proof generation, and prover orchestration remain the caller's responsibility.
Supply state through `StateReader` or an execution witness.

## Contributing

```sh
zig build test                       # native unit tests
zig build test-evmz-zkvm             # zkVM adapter semantics on the host
zig build ci -j2                     # complete deterministic local CI
zig build eest-test                  # EEST lane
zig build tidy                       # dead and unexercised declarations
zig build debug -- 6001600201        # interactive bytecode debugger
```

`tidy` reports review candidates and never edits source; pass `--strict` to
promote advisory findings.

## License

MIT — see [`LICENSE`](LICENSE).

Bundled third-party components retain their own licenses: c-kzg-4844 and blst
(Apache-2.0), EVMC/evmone headers (Apache-2.0), and mcl (BSD-3-Clause).
Distributions including them should reproduce the applicable license and NOTICE
files.
