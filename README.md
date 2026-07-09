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
- **Fast** — benchmarked against evmone and revm; strongest on storage-write
  and ERC20-style workloads.

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

Portable-release benchmark snapshot (median ms per call, lower is better):

Apple M1 Max

| VM-loop fixture     |    evmz | evmone-base | evmone-adv | revm-int |
| ------------------- | ------: | ----------: | ---------: | -------: |
| Arithmetic loop     | `0.230` |     `0.090` |    `0.325` |  `0.504` |
| Keccak loop         | `3.630` |     `3.608` |    `3.712` |  `2.917` |
| Storage SSTORE loop | `0.359` |     `1.157` |    `1.157` |  `1.150` |
| ERC20 mint          | `3.452` |     `4.257` |    `5.253` |  `3.977` |
| ERC20 transfer      | `6.268` |     `6.845` |    `8.089` |  `6.911` |

evmz leads on storage-heavy and ERC20 flows; evmone's baseline interpreter
still wins tight dispatch loops. Full methodology, fixtures, and commands are
in `bench/README.md`.

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
