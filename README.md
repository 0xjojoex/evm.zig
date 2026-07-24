# evm.zig

evm.zig is a fast and composable EVM execution engine, as a Zig library:

- a reusable library EVM with EVMC-compatible API
- Ethereum-derived with comptime fork, gas, opcode, and precompile
  specialization
- stateless block validation from execution witnesses
- and the same state transition function inside a zkVM guest
- a fast tail-call interpreter with a zero-alloc pooled executor

## Current Status

- glamsterdam devnet-7: `67,066/67,066` EEST state vectors passing (`tests-glamsterdam-devnet@v7.2.0`)

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

## Example

```zig
const evmz = @import("evmz");

// In-memory state backend for the example; bring your own StateReader in real use.
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

// Execution is complete, but its rollback cursor remains armed.
const result = try execution.result();
// result.status, result.gas.used, result.output
const changes = execution.changes();
```

Consume or persist the borrowed `changes` before resolving the execution. Then
call `execution.retain()` to extend the accepted branch, or let the deferred
discard restore the pre-transaction branch. A block committer consumes
`executor.acceptedChanges()` once and calls `executor.discardAccepted()` after
the backend accepts it.

A complete runnable version — deploy code, transact, read storage back — lives
in `examples/basic.zig`:

```sh
zig build example
```

## Choose a fork

`Evm` is the latest exact Ethereum VM. Bind another complete specification at
compile time; runtime fork selection belongs to its caller:

```zig
const CancunVM = evmz.Vm(evmz.eth.cancun);
```

## Extend Ethereum

Each Ethereum fork is one complete `Spec`. Extend the exact base you mean, then
compile that value into one concrete VM:

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

See `examples/custom_fork/` for exact-spec overrides and
`examples/op_deposit.zig` for an extending spec chain, custom transactions,
and caller-side runtime selection.

The dependency flows one way: `evmz.spec` defines the engine contract, while
`evmz.eth` supplies named Ethereum fork values. Extensions have three tiers:

- parameter — patch numbers, toggles, or semantic functions with `Spec.extend`;
- table — replace the complete instruction or precompile binding;
- program — bind a custom transaction envelope, transition, or block fold
  through the exact VM’s `Context`, `Transition`, `Program`, and `Block` APIs.

## EVMC compatibility package

```sh
zig build evmc -Doptimize=ReleaseFast
zig build evmc-test
zig build evmc-example -Doptimize=ReleaseFast
```

The standalone `pkg/evmc` package builds static and shared `libevmz-evmc`
artifacts exporting `evmc_create_evmz`. It owns the EVMC headers and C example
while depending on the public `evmz` engine module. The root `include/evmz/evmz.h`
path remains reserved for a future native evmz C API.

## Benchmarks

Fixed-Osaka benchmark snapshots use native ReleaseFast builds and explicitly
omit frame pointers for every engine. Lower is better.

### Apple M1 Max / macOS arm64

The Apple snapshot enables evmz's optional XKCP Keccak and libsecp256k1
providers for its maximum-performance configuration. It uses a 100 ms discarded
warmup and five complete repeats; each cell is the median of five 100-run
medians per deployed-runtime call:

`zig build bench-compare -Dbench-optimize=ReleaseFast -Dbench-support-min=osaka -Dbench-support-max=osaka -Dnative-keccak=xkcp -Dnative-secp256k1=libsecp256k1 -- --spec osaka --num-runs 100 --warmup-ms 100`

| VM-loop fixture         |      evmz | evmone-base | evmone-adv |  revm-int | base/evmz | revm/evmz |
| ----------------------- | --------: | ----------: | ---------: | --------: | --------: | --------: |
| Arithmetic loop         |  0.119 ms |    0.099 ms |   0.325 ms |  0.489 ms |     0.83× |     4.11× |
| Memory MSTORE loop      |  0.136 ms |    0.083 ms |   0.252 ms |  0.403 ms |     0.61× |     2.96× |
| Keccak loop             |  2.652 ms |    3.508 ms |   3.589 ms |  2.697 ms |     1.32× |     1.02× |
| Ten-thousand hashes     |  0.916 ms |    0.742 ms |   1.629 ms |  2.036 ms |     0.81× |     2.22× |
| Storage SLOAD loop      |  0.189 ms |    0.589 ms |   0.644 ms |  0.350 ms |     3.12× |     1.85× |
| Storage SSTORE loop     |  0.196 ms |    0.866 ms |   0.879 ms |  0.858 ms |     4.42× |     4.38× |
| LOG0 / 0-byte data      |  0.045 ms |    0.030 ms |   0.081 ms |  0.127 ms |     0.66× |     2.81× |
| LOG0 / 32-byte data     |  0.050 ms |    0.033 ms |   0.081 ms |  0.308 ms |     0.66× |     6.17× |
| LOG4 / 0-byte data      |  0.086 ms |    0.078 ms |   0.148 ms |  0.264 ms |     0.90× |     3.08× |
| LOG4 / 32-byte data     |  0.102 ms |    0.082 ms |   0.147 ms |  0.409 ms |     0.81× |     4.01× |
| ERC20 mint              |  1.869 ms |    3.817 ms |   4.717 ms |  3.625 ms |     2.04× |     1.94× |
| ERC20 transfer          |  3.859 ms |    6.183 ms |   7.423 ms |  6.088 ms |     1.60× |     1.58× |
| ERC20 approval+transfer |  3.485 ms |    4.936 ms |   5.950 ms |  4.665 ms |     1.42× |     1.34× |
| Snailtracer             | 20.495 ms |   59.606 ms |  78.840 ms | 37.704 ms |     2.91× |     1.84× |

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
