# evm.zig

**A Zig EVM engine you can embed, fork, and inspect.**

evm.zig is the execution engine as a library: hand it state and a transaction,
get back the result and a changeset. The engine is generic over a chain
definition — Ethereum's forks, gas tables, and precompiles ship as one preset,
and a custom EVM-family chain is just another Zig type. It passes all `66,668`
locked Ethereum Execution Spec state tests and benchmarks head-to-head with
evmone and revm.

Where it's going: a stateless, provable EVM — the same engine built out into a
witness-in, roots-out state-transition function that runs as a zkVM guest.

- **Spec-tested** — `66,668/66,668` EEST state vectors passing
  (`tests-glamsterdam-devnet@v6.1.0`).
- **Embeddable** — pure Zig API, plus an EVMC-compatible C ABI
  (`evmc_create_evmz`).
- **Programmable** — swap forks, gas tables, opcodes, and precompiles by
  writing a definition type, not by forking the interpreter.
- **Fast** — tail-call fast lane plus pooled executor; leads measured ERC20 and
  warm-SSTORE fixtures while publishing the losing rows against evmone/revm.

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

const result = try vm.transact(.{
    .sender = evmz.addr(0xaaaa),
    .to = evmz.addr(0xbbbb),
    .gas_limit = 100_000,
});
// result.status, result.gas_used, result.output
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
const CancunVm = evmz.Vm(evmz.eth.fork(.cancun));
```

## Bring your own chain

Ethereum's constants, gas tables, and activation schedule live in one preset:
`evmz.eth`. A custom EVM-family chain — different gas costs, forks, or
precompile addresses — is another definition value bound the same way:

```zig
const MyVm = evmz.Vm(evmz.Protocol(MyChainDefinition, .{}));
```

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

Fixed-Osaka benchmark snapshot (Apple M1 Max, ReleaseFast, median ms per
deployed-runtime call; lower is better):

`zig build bench-compare -Dbench-optimize=ReleaseFast -Dbench-support-min=osaka -Dbench-support-max=osaka -- --spec osaka`

| VM-loop fixture          |     evmz | evmone-base | evmone-adv | revm-int |
| ------------------------ | -------: | ----------: | ---------: | -------: |
| Arithmetic loop          |  `0.156` |     `0.090` |    `0.325` |  `1.196` |
| Memory MSTORE loop       |  `0.145` |     `0.089` |    `0.256` |  `0.986` |
| Keccak loop              |  `3.549` |     `3.555` |    `3.629` |  `5.277` |
| Ten-thousand hashes      |  `1.179` |     `0.739` |    `1.583` |  `4.313` |
| Storage SLOAD loop       |  `0.140` |     `0.076` |    `0.101` |  `0.337` |
| Storage SSTORE loop      |  `0.360` |     `1.136` |    `1.163` |  `1.754` |
| LOG0 loop                |  `0.098` |     `0.030` |    `0.081` |  `0.134` |
| ERC20 mint               |  `3.159` |     `4.273` |    `5.157` |  `5.302` |
| ERC20 transfer           |  `5.673` |     `6.589` |    `7.905` |  `9.703` |
| ERC20 approval+transfer  |  `4.896` |     `5.240` |    `6.164` |  `8.058` |
| Snailtracer              | `60.457` |    `57.049` |   `76.005` | `60.559` |

<details>
<summary>The evmz approach</summary>

evmz bets on compile-time protocol specialization. A protocol (fork range, gas
schedules, opcode availability, dispatch targets) is a comptime value; the
256-entry dispatch table, static gas constants, and fork gates are resolved at
build time and baked into the binary. There is no runtime revision branching on
the hot path — a fork-gated opcode either compiles to a direct handler
(available across the whole supported range), a cheap revision check, or falls
out of the fast lane entirely.

Execution is two-tier. A narrow tail-call fast lane covers the hot,
always-available opcodes with machine state (instruction pointer, stack pointer,
gas) carried in registers as tail-call arguments. Everything else — fork-gated
ops, custom dispatch overrides, CALL/CREATE, tracing — spills to the generic
handler set that operates on the full CallFrame. The seam is explicit: custom
fork configurations and opcode overrides never tax the hot lane; they simply
route to the cold tier.

Around the interpreter sits a zero-alloc, pooled executor: frames, stacks,
messages, and IO buffers live in preallocated slots (optionally hard-bounded for
embedded/zkVM targets), and the state journal is cheap enough that the full
executor benches within noise of the raw interpreter. This is why evmz is
fastest of all measured engines on the realistic fixtures (ERC-20
mint/transfer, warm-SSTORE) even where it trails on synthetic single-opcode
loops.

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
