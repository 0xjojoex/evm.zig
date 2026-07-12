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

const executed = switch (try vm.transact(.{
    .sender = evmz.addr(0xaaaa),
    .to = evmz.addr(0xbbbb),
    .gas_limit = 100_000,
})) {
    .executed => |value| value,
    .rejected => return error.TransactionRejected,
};
// executed.status, executed.gas.used, executed.output
// vm.changeset() gives you the state diff to commit or discard.
```

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
`Transaction`, `TxResult`, and `TxStatus` types. Lowercase modules such as
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

Fixed-Osaka benchmark snapshots (native ReleaseFast, frame pointers explicitly
omitted for every engine, 100 ms discarded warmup, three complete repeats;
each cell is the median of three 100-run medians per deployed-runtime call;
lower is better):

`for _ in 1 2 3; do zig build bench-compare -Dbench-optimize=ReleaseFast -Dbench-support-min=osaka -Dbench-support-max=osaka -- --spec osaka --num-runs 100 --warmup-ms 100; done`

`base/evmz` and `revm/evmz` divide competitor time by evmz time: above `1×`
means evmz is faster. Raw milliseconds are comparable only within the same
platform. Storage rows use a fresh mock host per call with value and warmth
tracked independently: the first slot access is cold and the next 7,999 are
warm. They measure VM plus each engine's native mock host, not pure opcode cost.

### Apple M1 Max / macOS arm64

| VM-loop fixture | evmz | evmone-base | evmone-adv | revm-int | base/evmz | revm/evmz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Arithmetic loop | `0.160 ms` | `0.102 ms` | `0.326 ms` | `0.504 ms` | `0.64×` | `3.15×` |
| Memory MSTORE loop | `0.150 ms` | `0.089 ms` | `0.260 ms` | `0.421 ms` | `0.60×` | `2.81×` |
| Keccak loop | `3.685 ms` | `3.595 ms` | `3.680 ms` | `2.760 ms` | `0.98×` | `0.75×` |
| Ten-thousand hashes | `1.082 ms` | `0.755 ms` | `1.662 ms` | `2.119 ms` | `0.70×` | `1.96×` |
| Storage SLOAD loop | `0.312 ms` | `0.624 ms` | `0.648 ms` | `0.355 ms` | `2.00×` | `1.14×` |
| Storage SSTORE loop | `0.338 ms` | `0.881 ms` | `0.906 ms` | `0.869 ms` | `2.61×` | `2.57×` |
| LOG0 / 0-byte data | `0.066 ms` | `0.031 ms` | `0.083 ms` | `0.133 ms` | `0.48×` | `2.02×` |
| LOG0 / 32-byte data | `0.073 ms` | `0.035 ms` | `0.085 ms` | `0.313 ms` | `0.47×` | `4.29×` |
| LOG4 / 0-byte data | `0.085 ms` | `0.090 ms` | `0.150 ms` | `0.267 ms` | `1.06×` | `3.14×` |
| LOG4 / 32-byte data | `0.092 ms` | `0.087 ms` | `0.151 ms` | `0.419 ms` | `0.94×` | `4.55×` |
| ERC20 mint | `2.805 ms` | `3.914 ms` | `4.816 ms` | `3.750 ms` | `1.40×` | `1.34×` |
| ERC20 transfer | `5.457 ms` | `6.373 ms` | `7.621 ms` | `6.492 ms` | `1.17×` | `1.19×` |
| ERC20 approval+transfer | `4.874 ms` | `5.204 ms` | `6.179 ms` | `4.801 ms` | `1.07×` | `0.98×` |
| Snailtracer | `27.552 ms` | `62.131 ms` | `82.245 ms` | `39.656 ms` | `2.25×` | `1.44×` |

### AMD EPYC Genoa / Linux x86-64

The Linux snapshot ran on a KVM guest pinned to one CPU.

| VM-loop fixture | evmz | evmone-base | evmone-adv | revm-int | base/evmz | revm/evmz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Arithmetic loop | `0.139 ms` | `0.141 ms` | `0.338 ms` | `0.374 ms` | `1.01×` | `2.69×` |
| Memory MSTORE loop | `0.177 ms` | `0.263 ms` | `0.285 ms` | `0.307 ms` | `1.49×` | `1.74×` |
| Keccak loop | `4.576 ms` | `4.570 ms` | `4.605 ms` | `10.989 ms` | `1.00×` | `2.40×` |
| Ten-thousand hashes | `1.977 ms` | `1.879 ms` | `2.067 ms` | `2.608 ms` | `0.95×` | `1.32×` |
| Storage SLOAD loop | `0.576 ms` | `0.539 ms` | `0.543 ms` | `0.636 ms` | `0.94×` | `1.10×` |
| Storage SSTORE loop | `0.591 ms` | `0.808 ms` | `0.838 ms` | `1.231 ms` | `1.37×` | `2.08×` |
| LOG0 / 0-byte data | `0.063 ms` | `0.043 ms` | `0.088 ms` | `0.099 ms` | `0.68×` | `1.59×` |
| LOG0 / 32-byte data | `0.068 ms` | `0.050 ms` | `0.093 ms` | `0.200 ms` | `0.72×` | `2.92×` |
| LOG4 / 0-byte data | `0.104 ms` | `0.112 ms` | `0.256 ms` | `0.212 ms` | `1.08×` | `2.05×` |
| LOG4 / 32-byte data | `0.111 ms` | `0.112 ms` | `0.208 ms` | `0.310 ms` | `1.01×` | `2.80×` |
| ERC20 mint | `3.949 ms` | `4.226 ms` | `4.722 ms` | `7.112 ms` | `1.07×` | `1.80×` |
| ERC20 transfer | `7.491 ms` | `7.516 ms` | `8.418 ms` | `14.848 ms` | `1.00×` | `1.98×` |
| ERC20 approval+transfer | `6.456 ms` | `6.219 ms` | `6.991 ms` | `13.445 ms` | `0.96×` | `2.08×` |
| Snailtracer | `35.122 ms` | `58.486 ms` | `70.647 ms` | `53.465 ms` | `1.67×` | `1.52×` |

Across both snapshots, evmz leads SSTORE and snailtracer and stays competitive
on complete ERC20 workloads. SLOAD is 2× faster than evmone baseline on Apple
arm64 and roughly 7% slower on Linux. Native LOG4 is within 8% of baseline on
both platforms; LOG0 remains the residual LOG gap at roughly 2.1× baseline on
Apple and 1.5× on Linux. Arithmetic, MSTORE, and some engine rankings remain
platform-sensitive.

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
executor benches within noise of the raw interpreter. Evmz leads SSTORE and
snailtracer on both snapshots; ERC20 moves from clear wins on Apple arm64 to
within 4% of evmone baseline on Linux. SLOAD leads on Apple and narrows to a
roughly 7% Linux gap. Native LOG4 now matches baseline, leaving LOG0 as the
remaining host-bound dispatch gap.

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
