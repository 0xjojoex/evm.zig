# evmz

A fast, composable EVM execution engine in Zig. One exact Ethereum specification —
dispatch table, gas schedule, precompiles, transaction rules, and block hooks —
is a compile-time value, resolved into one concrete VM with no runtime fork
selection. The same block state transition function runs natively and as an
RV64 guest on SP1 and ZisK.

## Status

evmz is pre-release. The version is `0.0.0`, the public API may change between
commits, and the project has not been audited. `67,066/67,066` EEST vectors
pass for Glamsterdam devnet-7.

Implemented:

- Ethereum execution through Glamsterdam devnet-7, whose execution-layer fork is
  Amsterdam
- Stateless block validation from execution witnesses
- Native, SP1, and ZisK execution of the stateless validator

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
    .state = .{ .reader = memory.reader() },
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

Run the full test suite through the zkVM adapters on the host, with no RV64
toolchain or vendor library required:

```sh
zig build test-evmz-zkvm
```

Building a guest ELF requires the backend's static provider library:

```sh
zig build guest-zisk -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
    -Dziskos-staticlib=/path/to/libziskos_staticlib.a

zig build guest-sp1 -Dguest-payload=stateless-ere -Doptimize=ReleaseFast \
    -Dsp1-staticlib=/path/to/libzkevm.a
```

The matching `guest-zisk-run` and `guest-sp1-run` steps execute the built ELF
on the backend emulator; pass `-Dguest-input=<file>` for the stateless input
and `-Dguest-output=<file>` to capture public output. ZisK runs use `ziskemu`
from `PATH` unless `-Dziskemu` points elsewhere; the SP1 run step builds its
host driver with Cargo on demand.

See [`guest/README.md`](guest/README.md) for provider setup, heap and RAM
sizing, schema pinning, and proof-readiness checks.

## Performance

Representative Apple M1 Max VM-loop results from the fixed-Osaka `ReleaseFast`
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

</details>

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

Licensed under either of:

- Apache License, Version 2.0 ([`LICENSE-APACHE`](LICENSE-APACHE))
- MIT license ([`LICENSE-MIT`](LICENSE-MIT))

at your option.

Bundled third-party components retain their own licenses: c-kzg-4844 and blst
(Apache-2.0), and mcl (BSD-3-Clause).
Distributions including them should reproduce the applicable license and NOTICE
files.
