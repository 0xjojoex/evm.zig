# evm.zig Benchmark Lab

This sidecar is for measurement harnesses that are not EEST fixtures.

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

`zig build vm-loop` implements the simple evm-bench fixture protocol for evmz
and evmone. `zig build revm-vm-loop` runs the same fixtures through revm's
low-level interpreter path:

```sh
cd bench
zig build vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes
zig build vm-loop -- --engine evmone --fixture fixtures/vm-loop/ten-thousand-hashes
zig build revm-vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes
zig build vm-loop -- --fixture fixtures/vm-loop/erc20-mint --summary
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
The evmz runner times only `Interpreter.execute()` after call-frame setup. The
evmone runner uses a fixture-scoped VM and times EVMC `execute()`.

Host profiles:

- `--host-profile null`: fail after execution if the run touched host callbacks.
  Use this for pure opcode, memory, jump, arithmetic, and keccak benchmarks.
- `--host-profile mock`: provide deterministic in-memory storage/account/log
  callbacks. Use this for VM + mock-host measurements, not pure VM claims.

Precompiles and real state execution should stay in dedicated kernel or
integration lanes. This layer is intentionally about deployed runtime bytecode
calls. The evmone runner uses the same simple Zig mock host as evmz. The revm
VM-loop runner analyzes bytecode and times `Interpreter::run_plain()` with a
small in-memory host; it does not include revm transaction validation,
finalization, or journal/database setup.

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
`Interpreter.execute()` after bytecode generation and interpreter
initialization. It uses the null host and fails if a case touches host callbacks.
The default comparison mode is portable release: Zig uses `ReleaseFast`, evmone
is compiled into the Zig benchmark binary with the same optimization mode, and
revm uses Cargo `--release`. The harness does not enable CPU-native flags such
as `-march=native` or `target-cpu=native`; if we add those later, they should be
reported as a separate native-release lane.

Kernel case bytecode lives in `fixtures/kernel/*.hex`. Both the Zig runner and
the revm sidecar read the same fixture files, then repeat or cycle non-empty
lines to build the requested iteration count. Branch fixtures use repeatable
relative `PC + offset` targets so the same fixture line can be reused at any
bytecode offset.

```sh
cd bench
zig build kernel -- --case mulmod --case addmod --repeats 5 --warmups 1
zig build kernel -- --case push-pop --iterations 1000000 --repeats 3
zig build kernel -- --engine evmz --engine evmz-call-total --engine evmone-baseline --engine evmone --case add
zig build revm-kernel -- --case add --case mulmod
zig build kernel -- --engine evmz --engine evmz-call-total --engine evmone-baseline --engine evmone --tier edge --tier branch --iterations 10000
```

CSV columns:

```text
suite,engine,case,repeat,iterations,bytecode_bytes,elapsed_ns,ns_per_iter,gas_used,host_calls
```

The Zig kernel runner supports `evmz`, `evmone-baseline`, and
`evmone-advanced` (`evmone` is an alias for advanced mode). The `evmz` row
times only `Interpreter.execute()` after bytecode generation and interpreter
initialization. Use `evmz-call-total` for an evmz row that includes interpreter
initialization and bytecode analysis; this is the row to inspect for
JUMPDEST-heavy or large-bytecode cases. evmone rows time the EVMC `execute`
call.

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

`zig build report` runs the VM-loop fixtures across evmz/evmone/revm, the
host-boundary matrix, opcode kernels against evmz/evmone/revm, and a small
representative EEST integration slice. It writes raw CSVs, a Markdown report,
and a compact evmz checkpoint JSON:

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

The default lane is portable release: Zig `ReleaseFast`, evmone built into the
Zig bench binary with the same optimization mode, and revm `cargo --release`.
Reports and checkpoints should stay under ignored `output/`; they are local
measurement artifacts, not source fixtures. Use `--checkpoint <path>` to write
the compact JSON somewhere stable. Use `--baseline <path>` to include
evmz-vs-evmz deltas in the report after an optimization branch.
