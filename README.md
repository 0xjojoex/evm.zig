# evmz

A fast, composable EVM execution engine in Zig.

An Ethereum specification — opcode dispatch table, gas schedule, precompiles,
transaction rules, and block hooks — is a compile-time `Spec` value compiled
into one concrete machine with no runtime fork switches. The same state
transition function runs natively and as an RV64 guest on ZisK, SP1, and OpenVM.

## Why evmz

evmz does not ship one general interpreter with runtime feature flags. Choices
that other engines branch on per instruction — fork rules, tracing,
single-stepping, custom opcodes, pool bounds — are resolved at compile time from
one semantic definition:

- **Default (`Interpreter`)** — tail-call dispatch. Each handler charges gas,
  executes, and tail-calls the next instruction with no central dispatch loop.
- **Trace** — a separate compilation whose dispatch table interleaves trace
  hooks with the same handlers, keeping observability free on the default path.
- **Step (`debug.SessionType`)** — replaces tail-chaining with per-instruction
  yielding for deterministic single-step debugging.
- **Pooled executor (`Executor`)** — frames, stacks, messages, and I/O buffers
  live in preallocated slots with a low-overhead state journal. Hard-bounding
  those pools produces the zkVM guest machine with zero dead branches in the
  proving trace.

## Status

Pre-release (`0.0.0`, unaudited; APIs may change between commits).

- **Implemented:** Ethereum execution through Amsterdam (Glamsterdam
  prerelease), stateless block validation from execution witnesses, and RV64
  stateless validator guests for ZisK, SP1, and OpenVM.
- **Experimental:** Block Access List (`BalVm` / `ClosedWorld`) validation and
  parallel verification, custom transaction/block hooks, and the C header slot.

## Install

Requires **Zig 0.17.x** (CI and `mise.toml` pin **0.17.1**).

```sh
zig fetch --save git+https://github.com/0xjojoex/evm.zig
```

Import the modules you need in `build.zig`:

```zig
const evmz = b.dependency("evmz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("evmz", evmz.module("evmz"));
exe.root_module.addImport("rlp", evmz.module("rlp")); // also: "mpt", "ssz"
```

| Build option | Default | Effect |
| --- | --- | --- |
| `.core = false` | `true` | Export only pure-Zig `rlp`, `mpt`, and `ssz` without fetching C/C++ crypto dependencies |
| `.profile = .zkvm` | `.native` | Route crypto and precompiles through the `zkvm_accelerators.h` C ABI |
| `.@"native-keccak" = .std` | `.xkcp` | Use `std` Keccak instead of XKCP assembly (`x86_64`, `aarch64`, `riscv64`) |
| `.pic = true` | `false` | Build position-independent code |

## Quick start

```zig
const std = @import("std");
const evmz = @import("evmz");

// Use your own StateReader in production.
var memory = evmz.state.MemoryStore.init(allocator);
defer memory.deinit();

var vm = evmz.Evm.init(allocator, .{
    .state = .{ .reader = memory.reader() },
});
defer vm.deinit();

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
std.debug.print("status: {t}, gas: {}\n", .{
    result.status,
    result.gas.used,
});

// Commit into the VM's pending branch (otherwise `discardIfCurrent` rolls back).
execution.retain();
```

`retain()` accepts the execution into the VM's pending branch; block-level
callers can consume `vm.executor.acceptedChanges()` and persist it. See
[`examples/basic.zig`](examples/basic.zig) for a runnable transaction example,
[`examples/transaction_journal.zig`](examples/transaction_journal.zig) for host
state that rolls back with the EVM, and
[`examples/bal_parallel.zig`](examples/bal_parallel.zig) for Block Access List
execution.

## Execution surfaces

Each tier strips outer protocol concerns before calling the next:

| Surface | Entry point | Responsibility |
| --- | --- | --- |
| Bytecode | `Vm.Interpreter` | Single call-frame bytecode execution |
| Message | `Vm.Executor.executeMessage` | Root `call \| create` execution, child frames, and state journaling |
| Transaction | `Vm.transact` | Envelope validation, nonce/fee accounting, warm sets, and receipts |
| Block | `block.Stf` | System calls, ordered transactions, withdrawals, and requests |
| Stateless | `stateless.Exact(fork)` | Witness verification and post-state / receipts root computation |
| Guest | [`guest/`](guest/README.md) | Stateless validator compiled to RV64 ELFs for ZisK, SP1, and OpenVM |

## Customizing specifications

`evmz.Evm` aliases `evmz.Vm(evmz.eth.latest)`. Pass any built-in fork or derive
a custom specification at comptime with `Spec.extend`:

```zig
const CancunEvm = evmz.Vm(evmz.eth.cancun);

const my_spec = evmz.eth.cancun.extend(.{
    .transaction = .{
        .max_initcode_size = 0x10000,
    },
    .settlement = .{
        .gas_refund_cap_divisor = 4,
    },
});
const CustomEvm = evmz.Vm(my_spec);
```

`Spec.extend` patches scalar parameters, gas functions, opcodes, precompiles,
native contracts, and block hooks:

- [`examples/custom_fork/`](examples/custom_fork/README.md) — tour of every
  `Spec.extend` seam
- [`examples/op/`](examples/op/) — OP Stack family specification
- [`doc/native-contracts.md`](doc/native-contracts.md) — precompiles vs.
  stateful native contracts vs. predeploys vs. system calls

## Stateless validation and zkVM guests

`evmz.stateless` validates a block from an execution witness and returns its
post-state and receipts roots:

```zig
const Validator = evmz.stateless.Exact(.amsterdam);
const result = try Validator.validate(allocator, input);
```

Test the zkVM accelerator path natively on the host without an RV64 toolchain,
or build the RV64 guest ELFs:

```sh
zig build test-evmz-zkvm

zig build guest-zisk -Dguest-payload=stateless-ere -Doptimize=fast \
    -Dziskos-staticlib=/path/to/libziskos_staticlib.a
zig build guest-sp1 -Dguest-payload=stateless-ere -Doptimize=fast
zig build guest-openvm -Dguest-payload=stateless-ere -Doptimize=fast
```

`guest-zisk-run` and `guest-sp1-run` execute the built ELF on the backend
emulator with `-Dguest-input=<file>` and `-Dguest-output=<file>`. See
[`guest/README.md`](guest/README.md) for provider setup, heap/RAM sizing,
schema pinning, and proof verification.

## Codec & trie modules

Exported from the root package (pass `.core = false` to `b.dependency` when you
only need these modules):

- [`pkg/rlp`](pkg/rlp/README.md) — strict RLP encoding and decoding
- [`pkg/mpt`](pkg/mpt/README.md) — stateless Merkle Patricia Trie proofs,
  authenticated catalogs, and sparse/fixed-key updates
- [`pkg/ssz`](pkg/ssz/README.md) — comptime-typed SSZ codec and zero-allocation
  `hash_tree_root`

## CLI tools

`zig build cli-build` installs `zig-out/bin/evmz` (or run `zig build <subcommand> -- <args>`):

- [`evmz t8n`](tools/t8n/README.md) — Ethereum state transition tool (Paris through Amsterdam)
- [`evmz statetest`](tools/statetest/README.md) — General State Test runner with EIP-3155 tracing
- [`evmz blocktest`](tools/blocktest/README.md) — raw block import and state root verification
- `evmz debug` — interactive and single-command bytecode debugger (`zig build debug -- 6001600201`)

## Performance

VM-loop interpreter medians on Apple M1 Max (macOS arm64, fixed Osaka,
`ReleaseFast`, XKCP Keccak, 5 × 100 calls after 100 ms warmup; lower is better):

| Fixture | evmz | evmone 0.25 base | EVM2 packed (Rust 1.96) |
| --- | ---: | ---: | ---: |
| Arithmetic loop | **0.092 ms** | 0.102 ms | 0.232 ms |
| Storage SSTORE loop | **0.162 ms** | 0.870 ms | 0.923 ms |
| ERC20 transfer | **3.694 ms** | 6.219 ms | 5.837 ms |
| Snailtracer | **19.898 ms** | 59.461 ms | 34.356 ms |

Full snapshots, host scope, and reproduction commands are in
[`bench/README.md`](bench/README.md#published-snapshots).

## Scope

evmz is an execution engine, not a client. It owns EVM execution, transaction
and block state transitions, stateless witness validation, and post-state /
receipts trie roots.

Networking, block sync, consensus-layer fork choice, RPC, persistent storage,
proof generation, and prover orchestration remain the caller's responsibility.
Supply state through `StateReader` or an execution witness.

## Contributing

```sh
mise trust && mise install           # install pinned Zig 0.17.1
zig build test                       # native unit tests (cancun, prague, .stable, .latest)
zig build test -Dtest-forks=head     # fastest inner loop (.latest only)
zig build test-evmz-zkvm             # zkVM adapter semantics on the host
zig build ci -j2                     # complete deterministic local CI
zig build eest-consume               # execution-specs conformance suite
zig build tidy                       # check for unused declarations and orphan files
```

`tidy` reports review candidates and never edits source; pass `-- --strict` to
promote advisory findings. See [`RELEASING.md`](RELEASING.md) for package
versioning, guest release tags, and release gates.

## License

Licensed under either of:

- Apache License, Version 2.0 ([`LICENSE-APACHE`](LICENSE-APACHE))
- MIT license ([`LICENSE-MIT`](LICENSE-MIT))

at your option.

Native builds link bundled third-party components under their own licenses:
`blst` (Apache-2.0), `mcl` (BSD-3-Clause), `libsecp256k1` (MIT), and `XKCP`
(CC0). Distributions including them should reproduce the applicable license and
NOTICE files.
