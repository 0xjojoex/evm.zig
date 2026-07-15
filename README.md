# evm.zig

**A Zig EVM engine you can embed, fork, and inspect.**

evm.zig is the execution engine as a library: hand it state and a transaction,
get back the result and a changeset. The engine is generic over a chain
definition — Ethereum's forks, gas tables, and precompiles ship as one preset,
and a custom EVM-family chain is another typed Definition value. It passes all `66,668`
locked Ethereum Execution Spec state tests and benchmarks head-to-head with
evmone and revm.

Where it's going: a stateless, provable EVM — the same engine built out into a
witness-in, roots-out state-transition function that runs as a zkVM guest.

- **Spec-tested** — `66,668/66,668` EEST state vectors passing
  (`tests-glamsterdam-devnet@v6.1.0`).
- **Embeddable** — pure Zig API, plus an EVMC-compatible C ABI
  (`evmc_create_evmz`).
- **Programmable** — swap forks, gas tables, opcodes, and precompiles by
  composing a definition value, not by forking the interpreter.
- **Fast** — tail-call fast lane plus pooled executor; competitive on ERC20
  across arm64 and x86-64, leading SSTORE and snailtracer rows while publishing
  the losing rows against evmone/revm.

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

## First transaction

```zig
const evmz = @import("evmz");

// In-memory state backend for the example; bring your own StateReader in real use.
var memory = evmz.state.MemoryStore.init(allocator);
defer memory.deinit();

var vm = evmz.Evm.init(allocator, .{
    .revision = .latest,
    .state_reader = memory.reader(),
    .env = .{ .gas_limit = 100_000 },
});
defer vm.deinit();

var pending = switch (try vm.transact(.{
    .sender = evmz.addr(0xaaaa),
    .to = evmz.addr(0xbbbb),
    .gas_limit = 100_000,
})) {
    .pending => |value| value,
    .rejected => return error.TransactionRejected,
};
defer pending.deinit(); // Rejects automatically if still unresolved.

// Inspect pending.result() and pending.logs(), then decide explicitly.
const executed = try pending.accept();
// executed.status, executed.gas.used, executed.output
// vm.changeset() gives you the state diff to commit or discard.
```

Use `vm.transactCommit(tx)` when the VM has a committer and the transaction
should be accepted and persisted in one call.

A complete runnable version — deploy code, transact, read storage back — lives
in `examples/basic.zig`:

```sh
zig build example
```

## Pin a fork

`Evm` tracks the latest supported revision and lets you pick one at
runtime. If your embedder targets exactly one fork, bind it at compile time:

```zig
const CancunVM = evmz.EvmWith(.{
    .support = evmz.Evm.Support.at(.cancun),
});
```

## Bound runtime resources

Normal initialization is infallible and growable. Embedded and zkVM callers
can reserve a gas-derived capacity envelope explicitly:

```zig
var vm = try evmz.Evm.initBound(allocator, .{
    .revision = .cancun,
    .state_reader = memory.reader(),
    .env = .{ .gas_limit = 30_000_000 },
}, .{
    .max_block_gas = 30_000_000,
});

var block = try vm.beginBlock(.{ .gas_limit = 30_000_000 });
```

The bound controls allocation capacity; `Env.gas_limit` remains actual runtime
block data. Bounded VMs validate it against the allocation envelope and execute
transactions and system calls through `BlockSession`.

## Bring your own chain

Ethereum's constants, gas tables, and activation schedule live in one preset:
`evmz.eth`. A custom EVM-family chain — different gas costs, forks, or
precompile addresses — is another definition value bound the same way:

```zig
const MyVM = evmz.Vm(MyRevision, MyChainDefinition, .{});
```

The returned type carries its matching `Protocol`, `Executor`, `Interpreter`,
`Transaction`, `TransactResult`, `PendingTransaction`, `TxResult`, and
`TxStatus` types. Lowercase modules such as
`evmz.execution` and `evmz.executor` remain available for low-level work.
Representation-changing families can build a typed facade over those APIs;
[`examples/op-deposit.zig`](examples/op-deposit.zig) is a compact example.

`evmz.protocol.assertValidDefinition` reports exactly what a definition must
provide, and `examples/custom-fork/` is a working downstream-style template.

## C / EVMC embedding

```sh
zig build -Doptimize=ReleaseFast
```

builds library artifacts exporting `evmc_create_evmz`, an EVMC-compatible
entrypoint. Public headers are in `include/`.

## Correctness and speed

State execution is validated against the locked Ethereum Execution Spec Tests
corpus: `66,668` state vectors, `0` failed, `0` skipped. The EEST runner and
fixture tooling live in `eest/`.

Fixed-Osaka benchmark snapshots use native ReleaseFast builds and explicitly
omit frame pointers for every engine. Lower is better.

### Apple M1 Max / macOS arm64

The Apple snapshot enables evmz's optional XKCP Keccak and libsecp256k1
providers for its maximum-performance configuration. It uses a 100 ms discarded
warmup and five complete repeats; each cell is the median of five 100-run
medians per deployed-runtime call:

`for _ in 1 2 3 4 5; do zig build bench-compare -Dbench-optimize=ReleaseFast -Dbench-support-min=osaka -Dbench-support-max=osaka -Dnative-keccak=xkcp -Dnative-secp256k1=libsecp256k1 -- --spec osaka --num-runs 100 --warmup-ms 100; done`

| VM-loop fixture | evmz | evmone-base | evmone-adv | revm-int | base/evmz | revm/evmz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Arithmetic loop | `0.142 ms` | `0.101 ms` | `0.334 ms` | `0.499 ms` | `0.71×` | `3.51×` |
| Memory MSTORE loop | `0.145 ms` | `0.086 ms` | `0.255 ms` | `0.412 ms` | `0.59×` | `2.84×` |
| Keccak loop | `2.725 ms` | `3.611 ms` | `3.696 ms` | `2.781 ms` | `1.33×` | `1.02×` |
| Ten-thousand hashes | `1.031 ms` | `0.754 ms` | `1.678 ms` | `2.093 ms` | `0.73×` | `2.03×` |
| Storage SLOAD loop | `0.304 ms` | `0.614 ms` | `0.657 ms` | `0.351 ms` | `2.02×` | `1.16×` |
| Storage SSTORE loop | `0.331 ms` | `0.867 ms` | `0.902 ms` | `0.875 ms` | `2.62×` | `2.64×` |
| LOG0 / 0-byte data | `0.065 ms` | `0.078 ms` | `0.083 ms` | `0.129 ms` | `1.20×` | `1.98×` |
| LOG0 / 32-byte data | `0.071 ms` | `0.033 ms` | `0.083 ms` | `0.312 ms` | `0.47×` | `4.39×` |
| LOG4 / 0-byte data | `0.081 ms` | `0.082 ms` | `0.150 ms` | `0.267 ms` | `1.01×` | `3.30×` |
| LOG4 / 32-byte data | `0.084 ms` | `0.084 ms` | `0.151 ms` | `0.413 ms` | `1.00×` | `4.91×` |
| ERC20 mint | `2.444 ms` | `3.924 ms` | `4.846 ms` | `3.753 ms` | `1.61×` | `1.54×` |
| ERC20 transfer | `4.515 ms` | `6.400 ms` | `7.649 ms` | `6.265 ms` | `1.42×` | `1.39×` |
| ERC20 approval+transfer | `3.909 ms` | `5.100 ms` | `6.108 ms` | `4.821 ms` | `1.30×` | `1.23×` |
| Snailtracer | `25.466 ms` | `61.415 ms` | `81.692 ms` | `39.384 ms` | `2.41×` | `1.55×` |


### AMD EPYC Genoa / Linux x86-64

The Linux snapshot ran on a KVM guest pinned to one CPU.

| VM-loop fixture | evmz | evmone-base | evmone-adv | revm-int | base/evmz | revm/evmz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Arithmetic loop | `0.151 ms` | `0.145 ms` | `0.331 ms` | `0.340 ms` | `0.96×` | `2.25×` |
| Memory MSTORE loop | `0.183 ms` | `0.263 ms` | `0.284 ms` | `0.308 ms` | `1.44×` | `1.69×` |
| Keccak loop | `4.597 ms` | `4.584 ms` | `4.680 ms` | `10.883 ms` | `1.00×` | `2.37×` |
| Ten-thousand hashes | `2.006 ms` | `1.880 ms` | `2.059 ms` | `2.513 ms` | `0.94×` | `1.25×` |
| Storage SLOAD loop | `0.584 ms` | `0.575 ms` | `0.548 ms` | `0.630 ms` | `0.98×` | `1.08×` |
| Storage SSTORE loop | `0.595 ms` | `0.838 ms` | `0.857 ms` | `1.112 ms` | `1.41×` | `1.87×` |
| LOG0 / 0-byte data | `0.060 ms` | `0.043 ms` | `0.088 ms` | `0.096 ms` | `0.73×` | `1.62×` |
| LOG0 / 32-byte data | `0.065 ms` | `0.049 ms` | `0.094 ms` | `0.202 ms` | `0.75×` | `3.08×` |
| LOG4 / 0-byte data | `0.107 ms` | `0.113 ms` | `0.239 ms` | `0.201 ms` | `1.06×` | `1.88×` |
| LOG4 / 32-byte data | `0.113 ms` | `0.113 ms` | `0.191 ms` | `0.307 ms` | `1.00×` | `2.71×` |
| ERC20 mint | `3.929 ms` | `4.204 ms` | `4.757 ms` | `6.991 ms` | `1.07×` | `1.78×` |
| ERC20 transfer | `7.686 ms` | `7.447 ms` | `8.433 ms` | `14.896 ms` | `0.97×` | `1.94×` |
| ERC20 approval+transfer | `6.278 ms` | `6.227 ms` | `7.032 ms` | `13.413 ms` | `0.99×` | `2.14×` |
| Snailtracer | `33.347 ms` | `57.983 ms` | `69.988 ms` | `52.417 ms` | `1.74×` | `1.57×` |


<details>
<summary>The evmz approach</summary>

evmz bets on compile-time protocol specialization. A protocol (fork range, gas
schedules, opcode availability, dispatch targets) is a comptime value; the
256-entry dispatch table, static gas constants, and fork gates are resolved at
build time and baked into the binary. There is no runtime revision branching on
the hot path — a fork-gated opcode either compiles to a direct handler
(available across the whole supported range), a cheap revision check, or falls
out of the fast lane entirely.

Execution is two-tier. Prepared tail dispatch carries machine state
(instruction pointer, stack pointer, gas) in registers and has dedicated
handlers for selected common operations, including storage. Fork-gated ops,
custom dispatch overrides, CALL/CREATE, and tracing spill to the generic
handler set that operates on the full CallFrame. Generic protocol hot/cold tier
metadata is a separate dispatch decision from prepared-tail handler selection.

Around the interpreter sits a zero-alloc, pooled executor: frames, stacks,
messages, and IO buffers live in preallocated slots (optionally hard-bounded for
embedded/zkVM targets), and the state journal is cheap enough that the full
executor benches within noise of the raw interpreter. Across both snapshots evmz
leads or holds parity with the baseline interpreter on the workload-shaped
fixtures, and comes out faster overall.

</details>

Full methodology, fixtures, and commands are in `bench/README.md`.

## Roadmap

- **Stateless validation** — block plus witness in, roots out: a pure
  state-transition function with its own Merkle Patricia Trie, built for
  verification instead of a database.
- **zkVM guest** — that same function compiled freestanding for RISC-V zkVMs,
  with hash and precompile accelerator seams already in place; early guest
  builds run under the ZisK emulator today. Existing stateless-validator
  guests are Rust — evm.zig is the Zig one.
- **Deeper chain programmability** — definition-owned transaction types,
  settlement, and precompile registries, so OP-, BSC-, and
  any EVM-style variants fit without touching the engine.

## Scope

evm.zig is the execution engine only. Networking, block sync, consensus,
trie/root validation, receipts, and persistent storage are an execution
client's job — you provide state through `StateReader`, evm.zig executes
against it.

## Contributing

```sh
zig build test        # unit tests
zig build eest-test   # spec-test lane
```

## License

MIT — see `LICENSE`.

Bundled third-party components keep their own licenses: c-kzg-4844
(Apache-2.0), blst (Apache-2.0), EVMC/evmone headers (Apache-2.0), and mcl
(BSD-3-Clause). Distributions including them should reproduce the applicable
license and NOTICE files.
