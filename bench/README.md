# evm.zig Benchmark Lab

This sidecar is for measurement harnesses that are not EEST fixtures.

## Overall Comparison

`zig build compare` is the VM-core scoreboard lane for the VM-loop fixtures. It
runs each engine through an interpreter-level path: evmz through direct
bound-interpreter `execute()`, evmone baseline and advanced through a
standalone C++ runner with analysis prepared once, and revm through the Rust
sidecar with analyzed `Bytecode`:

```sh
cd bench
zig build compare
zig build compare -- --fixture fixtures/vm-loop/erc20-transfer
```

From the repo root, use `zig build bench-compare`. Raw stdout/stderr plus
`summary.csv` and `summary.json` are written under ignored `zig-out/compare/`.
The compare lane defaults all engines to `--spec osaka`; pass `--spec` only
when intentionally testing another shared fork.
Use repeated `--engine` filters for narrower runs. `--engine evmz` runs only
evmz, while `--engine evmone` expands to both evmone baseline and advanced, and
`--engine revm` expands to `revm-interpreter`.

The executor/transaction comparison is intentionally a later lane. For now
`evmz-executor` remains available as a diagnostic target, but it is not mixed
into the VM-core scoreboard.

Current VM-core rows:

| engine             | level                         | prepared outside timing                                                                           | timed window                                    | transaction/overlay work |
| ------------------ | ----------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ------------------------ |
| `evmz`             | direct interpreter            | fixture loading, init-code deployment, frame/interpreter setup, jumpdest metadata preparation     | bound-interpreter `execute()`                   | no                       |
| `evmone-baseline`  | analyzed baseline interpreter | fixture loading, init-code deployment through EVMC, `baseline::analyze`                           | `baseline::execute` over `CodeAnalysis`         | no                       |
| `evmone-advanced`  | analyzed advanced interpreter | fixture loading, init-code deployment through EVMC, `advanced::analyze`                           | `advanced::execute` over `AdvancedCodeAnalysis` | no                       |
| `revm-interpreter` | raw interpreter loop          | fixture loading, init-code deployment, `Bytecode` legacy analysis; per-run interpreter/host setup | `Interpreter::run_plain`                        | no                       |

Future transaction/integration rows should stay separate, for example
`evmz-executor`, `revm-transact`, or an evmone transaction shim. Keep the
`scope` column visible whenever VM-core rows are compared.

## Micro Benchmarks

`zig build micro` runs focused zBench tests for inner-loop work. These are
Zig-only microscope checks for one implementation area, not cross-engine
comparisons:

```sh
cd bench
zig build micro -Dmicro-filter=micro/arithmetic
zig build micro -Dmicro-filter=sdiv
zig build micro -Dmicro-filter=mulmod
```

Micro benchmarks default to `ReleaseFast` even when the sidecar build default is
debug. Use `-Dmicro-optimize=ReleaseSafe` when a checked timing run is useful.
Each reported zBench run currently batches 256 helper calls so tiny arithmetic
helpers stay above timer noise. Keep tests split by function or feature so
`-Dmicro-filter` stays precise.

## VM-loop Runners

`zig build vm-loop` implements the simple evm-bench fixture protocol for evmz.
`zig build evmone-vm-loop` is the standalone C++ analyzed evmone runner used by
compare/report. `zig build revm-vm-loop` runs the same fixtures through revm's
low-level interpreter path:

```sh
cd bench
zig build vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes
zig build evmone-vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes --mode baseline
zig build revm-vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes
zig build vm-loop -- --fixture fixtures/vm-loop/erc20-mint --summary
zig build vm-loop -- --engine evmz --fixture fixtures/vm-loop/erc20-mint --summary
zig build vm-loop -- \
  --contract-code-path path/to/init-code.hex \
  --call-data 30627b7c \
  --num-runs 5
```

The runner deploys the contract once, then times repeated calls to the returned
runtime bytecode. Stdout contains one millisecond value per run so external
harnesses can consume it. Use `--summary` for host callback counts on stderr.
`--fixture` reads `init.hex`, `calldata.hex`, `num-runs.txt`, and
`host-profile.txt` from a fixture directory. CLI flags override fixture defaults.
The default evmz runner is direct bound-interpreter `execute()` with
metadata prepared before timing. Use `--engine evmz-executor` only for the
transaction/executor diagnostic stub; it prepares bytecode once and times
`Executor.executePreparedCallTransaction` after transaction setup/reset. The
standalone evmone runner prepares baseline or advanced analysis once and times
the analyzed execution path.

Host profiles:

- `--host-profile null`: fail after execution if the run touched host callbacks.
  Use this for pure opcode, memory, jump, arithmetic, and keccak benchmarks.
- `--host-profile mock`: provide deterministic in-memory storage/account/log
  callbacks. Use this for VM + mock-host measurements, not pure VM claims.

Precompiles and real state execution should stay in dedicated kernel or
integration lanes. This layer is intentionally about deployed runtime bytecode
calls. The standalone evmone runner and revm sidecar use small in-memory hosts
for the fixture protocol. The revm VM-loop runner analyzes bytecode and times
`Interpreter::run_plain()`; it does not include revm transaction validation,
finalization, or journal/database setup.

## Block lifecycle runner

`zig build block-lifecycle` measures the normal VM ownership shape for one block:
pre-state is seeded outside timing, then the timed window runs `Vm.init`,
`beginBlock`, a loop of protocol transactions, optional `commit`, and `Vm.deinit`.
This lane is for integration-level growable-vs-exact policy checks, not VM-core
dispatch comparisons.

```sh
cd bench
zig build block-lifecycle -- --policy growable --txs 1000 --summary
zig build block-lifecycle -- --policy exact-120m --txs 1000 --summary
```

The default case is `sstore-unique`, where each transaction writes a distinct
storage key through normal transaction execution. Use `--case noop` for lifecycle
overhead or `--case sstore-same` for repeated writes to the same slot. Stdout is
CSV:

```text
suite,policy,case,spec,repeat,txs,elapsed_ns,ns_per_tx,gas_used,block_gas_used,tx_count,commit
```

## Host-boundary runner

`zig build host-boundary` measures the native Zig host boundary. Direct
`host-*` operations call the `Host` vtable in a tight loop; `bytecode-*`
operations run repeated storage opcodes through the interpreter and the same
counting host.

```sh
cd bench
zig build host-boundary -- --op host-storage-read --iterations 1000000 --summary
zig build host-boundary -- --boundary evmc --op host-storage-read --iterations 1000000 --summary
zig build host-boundary -- --op bytecode-sload --iterations 100000 --summary
zig build host-matrix -- --op host-call --op host-storage-read --repeats 5 --warmups 1
```

`--boundary zig` is the native Zig `Host` vtable baseline. `--boundary evmc`
routes direct host operations through an EVMC-style `callconv(.c)` callback
bridge before entering the same counting host. Bytecode operations stay on the
interpreter + Zig host path.

`zig build host-matrix` runs the same measurement primitive repeatedly and emits
CSV:

```text
suite,op,boundary,repeat,iterations,elapsed_ns,ns_per_op,host_calls
```

By default it runs direct host operations across both `zig` and `evmc`
boundaries. Use repeated `--op` and `--boundary` filters for a smaller matrix;
use `--include-bytecode` to add `bytecode-sload` and `bytecode-sstore` rows.

## Opcode kernel runner

`zig build kernel` generates repeated opcode patterns and times only
bound-interpreter `execute()` after bytecode generation and interpreter
initialization. It uses the null host and fails if a case touches host callbacks.
The default comparison mode is native release for the Rust sidecar: Zig uses
`ReleaseFast`, evmone is compiled into the Zig benchmark binary with the same
optimization mode. Revm uses Cargo `--release` with
`RUSTFLAGS=-C target-cpu=native`, fat LTO, and one codegen unit.

Kernel case bytecode lives in `fixtures/kernel/*.hex`. Both the Zig runner and
the revm sidecar read the same fixture files, then repeat or cycle non-empty
lines to build the requested iteration count. Branch fixtures use repeatable
relative `PC + offset` targets so the same fixture line can be reused at any
bytecode offset.

```sh
cd bench
zig build kernel -- --case mulmod --case addmod --repeats 5 --warmups 1
zig build kernel -- --case push-pop --iterations 1000000 --repeats 3
zig build kernel -- --engine evmz --engine evmone-baseline --engine evmone --case add
zig build revm-kernel -- --case add --case mulmod
zig build kernel -- --engine evmz --engine evmone-baseline --engine evmone --tier edge --tier branch --iterations 10000
```

CSV columns:

```text
suite,engine,case,repeat,iterations,bytecode_bytes,elapsed_ns,ns_per_iter,gas_used,host_calls
```

The Zig kernel runner supports `evmz`, `evmone-baseline`, and
`evmone-advanced` (`evmone` is an alias for advanced mode). The `evmz` row
times only bound-interpreter `execute()` after bytecode generation and interpreter
initialization. evmone rows time the EVMC `execute` call.

The revm runner is a small Rust sidecar under `bench/revm`. It emits the same
CSV columns, but runs through revm's transaction API and reports execution gas
with the 21,000 intrinsic transaction gas subtracted. Treat it as a second
baseline, not a perfectly identical interpreter-only measurement.

Case tiers:

- `small`: existing straight-line dispatch/opcode kernels.
- `edge`: 256-bit arithmetic operands, signed high-bit operands, and wide EXP.
- `large`: large PUSH data and dense JUMPDEST bytecode.
- `branch`: repeatable relative `JUMP`/`JUMPI` programs.

## Comparison report

`zig build report` runs the VM-loop fixtures across evmz/evmone/revm,
the host-boundary matrix, and opcode kernels against evmz/evmone/revm. It
writes raw CSVs, a Markdown report, and a compact evmz checkpoint JSON:

```sh
cd bench
zig build report -- --out-dir ../output/bench-report
zig build report -- \
  --out-dir ../output/bench-report-after \
  --baseline ../output/bench-report/evmz-checkpoint.json
```

Root delegate:

```sh
zig build bench-report -- --out-dir ../output/bench-report
```

The default lane is native release for the Rust sidecar: Zig/C++ runners use
`ReleaseFast`, and revm uses `cargo --release` with `target-cpu=native`, fat
LTO, and one codegen unit.
Reports and checkpoints should stay under ignored `output/`; they are local
measurement artifacts, not source fixtures. Use `--checkpoint <path>` to write
the compact JSON somewhere stable. Use `--baseline <path>` to include
evmz-vs-evmz deltas in the report after an optimization branch.

Generated EEST benchmark fixtures are intentionally not part of this report
lane. The previous report integration mixed host, fixture, and precompile
semantics with VM timing, so future EEST benchmark reporting should first adapt
meaningful cases into the VM-loop protocol or a separate fair block-verdict
lane.
