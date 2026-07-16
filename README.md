# evm.zig

evm.zig is a fast and composable EVM execution engine, as a Zig library:

- a reusable library EVM with EVMC-compatible API
- protocol as a comptime value — swap forks, gas tables, opcodes, and
  precompiles by composition
- stateless block validation from execution witnesses
- and the same state transition function inside a zkVM guest
- a fast tail-call interpreter with a zero-alloc pooled executor

## Current Status

- glamsterdam: `66,668/66,668` EEST state vectors passing (`tests-glamsterdam-devnet@v6.1.0`)

## Ongoing Work

- Stateless validation
- zkVM guest
- Deeper chain programmability

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

## C / EVMC

```sh
zig build -Doptimize=ReleaseFast
```

builds library artifacts exporting `evmc_create_evmz`, an EVMC-compatible
entrypoint. Public headers are in `include/`.

## Benchmarks

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

| VM-loop fixture         |      evmz | evmone-base | evmone-adv |  revm-int | base/evmz | revm/evmz |
| ----------------------- | --------: | ----------: | ---------: | --------: | --------: | --------: |
| Arithmetic loop         |  0.120 ms |    0.102 ms |   0.325 ms |  0.489 ms |     0.85× |     4.08× |
| Memory MSTORE loop      |  0.136 ms |    0.083 ms |   0.251 ms |  0.400 ms |     0.61× |     2.94× |
| Keccak loop             |  2.656 ms |    3.505 ms |   3.587 ms |  2.697 ms |     1.32× |     1.02× |
| Ten-thousand hashes     |  0.882 ms |    0.740 ms |   1.629 ms |  2.034 ms |     0.84× |     2.31× |
| Storage SLOAD loop      |  0.300 ms |    0.585 ms |   0.644 ms |  0.350 ms |     1.95× |     1.17× |
| Storage SSTORE loop     |  0.330 ms |    0.848 ms |   0.898 ms |  0.858 ms |     2.57× |     2.60× |
| LOG0 / 0-byte data      |  0.045 ms |    0.030 ms |   0.081 ms |  0.127 ms |     0.66× |     2.81× |
| LOG0 / 32-byte data     |  0.050 ms |    0.033 ms |   0.083 ms |  0.285 ms |     0.66× |     5.70× |
| LOG4 / 0-byte data      |  0.086 ms |    0.069 ms |   0.147 ms |  0.264 ms |     0.81× |     3.09× |
| LOG4 / 32-byte data     |  0.103 ms |    0.082 ms |   0.148 ms |  0.408 ms |     0.80× |     3.96× |
| ERC20 mint              |  2.183 ms |    3.798 ms |   4.690 ms |  3.630 ms |     1.74× |     1.66× |
| ERC20 transfer          |  4.235 ms |    6.207 ms |   7.391 ms |  6.094 ms |     1.47× |     1.44× |
| ERC20 approval+transfer |  3.670 ms |    4.936 ms |   5.956 ms |  4.665 ms |     1.35× |     1.27× |
| Snailtracer             | 22.349 ms |   59.465 ms |  78.832 ms | 37.814 ms |     2.66× |     1.69× |

### AMD EPYC Genoa / Linux x86-64

The Linux snapshot ran on a KVM guest pinned to one CPU.

| VM-loop fixture         |      evmz | evmone-base | evmone-adv |  revm-int | base/evmz | revm/evmz |
| ----------------------- | --------: | ----------: | ---------: | --------: | --------: | --------: |
| Arithmetic loop         |  0.151 ms |    0.145 ms |   0.331 ms |  0.340 ms |     0.96× |     2.25× |
| Memory MSTORE loop      |  0.183 ms |    0.263 ms |   0.284 ms |  0.308 ms |     1.44× |     1.69× |
| Keccak loop             |  4.597 ms |    4.584 ms |   4.680 ms | 10.883 ms |     1.00× |     2.37× |
| Ten-thousand hashes     |  2.006 ms |    1.880 ms |   2.059 ms |  2.513 ms |     0.94× |     1.25× |
| Storage SLOAD loop      |  0.584 ms |    0.575 ms |   0.548 ms |  0.630 ms |     0.98× |     1.08× |
| Storage SSTORE loop     |  0.595 ms |    0.838 ms |   0.857 ms |  1.112 ms |     1.41× |     1.87× |
| LOG0 / 0-byte data      |  0.060 ms |    0.043 ms |   0.088 ms |  0.096 ms |     0.73× |     1.62× |
| LOG0 / 32-byte data     |  0.065 ms |    0.049 ms |   0.094 ms |  0.202 ms |     0.75× |     3.08× |
| LOG4 / 0-byte data      |  0.107 ms |    0.113 ms |   0.239 ms |  0.201 ms |     1.06× |     1.88× |
| LOG4 / 32-byte data     |  0.113 ms |    0.113 ms |   0.191 ms |  0.307 ms |     1.00× |     2.71× |
| ERC20 mint              |  3.929 ms |    4.204 ms |   4.757 ms |  6.991 ms |     1.07× |     1.78× |
| ERC20 transfer          |  7.686 ms |    7.447 ms |   8.433 ms | 14.896 ms |     0.97× |     1.94× |
| ERC20 approval+transfer |  6.278 ms |    6.227 ms |   7.032 ms | 13.413 ms |     0.99× |     2.14× |
| Snailtracer             | 33.347 ms |   57.983 ms |  69.988 ms | 52.417 ms |     1.74× |     1.57× |

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

## Packages

evm.zig builds on standalone Zig libraries under `pkg/`. Each has its own
`build.zig.zon` and can be fetched independently:

- [`pkg/rlp`](pkg/rlp) — strict RLP (Recursive Length Prefix) encoding and
  decoding.
- [`pkg/mpt`](pkg/mpt) — Merkle Patricia Trie primitives: canonical topology,
  proofs, and sparse updates over raw byte keys and values.
- [`pkg/ssz`](pkg/ssz) — comptime-typed SSZ (SimpleSerialize) codec for
  stateless verification and zkVM guests.

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
