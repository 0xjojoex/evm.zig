# evm.zig Benchmark Lab

This sidecar is for measurement harnesses that are not EEST fixtures.

## Overall Comparison

`zig build compare` is the VM-core scoreboard lane for the VM-loop fixtures. It
runs each engine through an interpreter-level path: evmz through direct
bound-interpreter `execute()`, evmone baseline and advanced through a
standalone C++ runner with analysis prepared once, and EVM2 through a Rust
sidecar with prepared bytecode:

```sh
cd bench
zig build compare
zig build compare -- --fixture fixtures/vm-loop/erc20-transfer
```

From the repo root, use `zig build bench-compare`. Raw stdout/stderr plus
`summary.csv` and `summary.json` are written under ignored `zig-out/compare/`.
Native builds default to XKCP Keccak on supported architectures, matching the
root build. Pass `-Dnative-keccak=std` to select Zig's implementation; standalone
`evmz-compare` and `scripts/report.py` accept `--native-keccak std` instead.
The compare lane defaults all engines to `--spec osaka`; pass `--spec` only
when intentionally testing another shared fork.
For the fair scoreboard, all compared engines explicitly omit frame pointers:
Zig/C++ modules use the corresponding compiler setting (and evmone C++ uses
`-fomit-frame-pointer`), while all Rust variants use `-C force-frame-pointers=no`.
The stable Rust rows use the pinned `1.96.0` toolchain, native CPU tuning, fat LTO,
and one codegen unit. Install it with `rustup toolchain install 1.96.0 --profile minimal`.
Use repeated `--engine` filters for narrower runs. `--engine evmz` runs only
evmz, while `--engine evmone` expands to both evmone baseline and advanced.
`--engine evm2` selects
`evm2-interpreter`.

The executor/transaction comparison is intentionally a later lane. For now
`evmz-executor` remains available as a diagnostic target, but it is not mixed
into the VM-core scoreboard.

Current VM-core rows:

| engine             | level                         | prepared outside timing                                                                           | timed window                                    | transaction/overlay work |
| ------------------ | ----------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ------------------------ |
| `evmz`             | exact-spec tail interpreter   | fixture loading, init-code deployment, frame/interpreter setup, jumpdest metadata preparation     | bound-interpreter `execute()`                   | no                       |
| `evmone-baseline`  | analyzed baseline interpreter | fixture loading, init-code deployment through EVMC, `baseline::analyze`                           | `baseline::execute` over `CodeAnalysis`         | no                       |
| `evmone-advanced`  | analyzed advanced interpreter | fixture loading, init-code deployment through EVMC, `advanced::analyze`                           | `advanced::execute` over `AdvancedCodeAnalysis` | no                       |
| `evm2-interpreter` | packed interpreter loop       | fixture loading, init-code deployment, forced jump analysis; per-run interpreter/host setup | `Interpreter::run` | no |

EVM2 is pinned to `f93318f120f6300599b21170d6c7bef81ed63d87`, the revision used
by Reth v2.9.0. The default build explicitly selects `EVM2_DISPATCH_BACKEND=packed`.
Only the standard library, map hasher, and assembly Keccak features are enabled: this lane never
executes precompiles or nested CALL/CREATE frames. LOG rows include each
interpreter's own log construction costs; the mock hosts discard logs.

All EVM2 interpreter variants emit an untimed reference call's gas used, deployed-code
hash, and return-output hash. `compare` rejects a mismatch between selected EVM2
interpreter rows. These fields, plus EVM2's dispatch, compiler version, and revision,
are retained in summary JSON/CSV and raw stderr. This is a bounded fixture check, not an EEST or full-block result.

```sh
zig build compare -- --engine evmz --engine evm2 --num-runs 100 --warmup-ms 100
zig build evm2-vm-loop -- --fixture fixtures/vm-loop/erc20-transfer --summary
cargo +1.96.0 test --locked --manifest-path evm2/Cargo.toml
```

Nightly EVM2 rows are opt-in. `evm2-tail` selects `EVM2_DISPATCH_BACKEND=tco`;
`evm2-packed-nightly` runs packed dispatch on the same `nightly-2026-06-01`
compiler, isolating dispatch changes from stable/nightly compiler differences.
Both keep the same dependency revision, feature set, and optimization flags.
Each variant has its own Cargo target directory to preserve its compiled binary
when switching backends. Summaries identify the compiled variant; the comparison
rejects a runner whose engine label differs from the requested row. JIT is separate.

```sh
rustup toolchain install nightly-2026-06-01 --profile minimal
zig build compare -- --engine evmz --engine evm2 \
  --engine evm2-packed-nightly --engine evm2-tail
zig build evm2-tail-vm-loop -- --fixture fixtures/vm-loop/arithmetic-loop --summary
zig build report -- --evm2-nightly
```

Future transaction/integration rows should stay separate, for example
`evmz-executor`, `evm2-transact`, or an evmone transaction shim. Keep the
`scope` column visible whenever VM-core rows are compared.

## Published snapshots

The current Apple M1 Max snapshot uses EVM2 stable packed dispatch. The AMD
snapshot retains its historical revm baseline. Both are fixed-Osaka, native
`ReleaseFast`, with frame pointers omitted for every engine. Lower is better;
ratios above `1.00×` mean evmz is faster than the named baseline.

### Apple M1 Max / macOS arm64 — 2026-10-30

Evmz explicitly selects the XKCP Keccak provider. EVM2 uses Rust 1.96.0, packed
dispatch and revision `f93318f120f6300599b21170d6c7bef81ed63d87`, pinned to
Reth v2.9.0. Rust uses native CPU tuning, fat LTO and one codegen unit.

Each cell is the median of five 100-call medians per deployed-runtime fixture,
with a 100 ms discarded warmup before each fixture/engine run. Engine order
rotates between rounds. These are interpreter-level measurements with the
fixture's null or mock host; deployment, bytecode preparation and per-call
interpreter/host setup are outside timing.

From the repository root, run this command five times with a distinct
`--out-dir`; rotate engine order with repeated `--engine` filters. Aggregate each fixture/engine's `median_ms`
from the five `summary.csv` files:

```sh
zig build bench-compare -Dbench-optimize=ReleaseFast \
  -Dbench-support-min=osaka -Dbench-support-max=osaka \
  -Dnative-keccak=xkcp \
  -- --spec osaka --num-runs 100 --warmup-ms 100 \
  --out-dir ../output/readme-evm2-20261030/round-1
```

| VM-loop fixture | evmz | evmone-base | evmone-adv | EVM2 packed | base/evmz | EVM2/evmz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Arithmetic loop | 0.092 ms | 0.110 ms | 0.328 ms | 0.238 ms | 1.19× | 2.59× |
| Memory MSTORE loop | 0.094 ms | 0.085 ms | 0.264 ms | 0.178 ms | 0.90× | 1.90× |
| Keccak loop | 2.740 ms | 3.602 ms | 3.723 ms | 2.580 ms | 1.31× | 0.94× |
| Ten-thousand hashes | 0.830 ms | 0.763 ms | 1.672 ms | 1.775 ms | 0.92× | 2.14× |
| Storage SLOAD loop | 0.149 ms | 0.592 ms | 0.665 ms | 0.450 ms | 3.97× | 3.02× |
| Storage SSTORE loop | 0.163 ms | 1.039 ms | 1.013 ms | 0.933 ms | 6.38× | 5.73× |
| LOG0 / 0-byte data | 0.044 ms | 0.030 ms | 0.082 ms | 0.090 ms | 0.68× | 2.04× |
| LOG0 / 32-byte data | 0.060 ms | 0.034 ms | 0.085 ms | 0.090 ms | 0.56× | 1.49× |
| LOG4 / 0-byte data | 0.089 ms | 0.070 ms | 0.152 ms | 0.115 ms | 0.78× | 1.29× |
| LOG4 / 32-byte data | 0.080 ms | 0.083 ms | 0.148 ms | 0.110 ms | 1.03× | 1.37× |
| ERC20 mint | 1.744 ms | 4.029 ms | 4.946 ms | 3.731 ms | 2.31× | 2.14× |
| ERC20 transfer | 3.704 ms | 6.435 ms | 7.841 ms | 5.889 ms | 1.74× | 1.59× |
| ERC20 approval+transfer | 3.409 ms | 5.063 ms | 6.120 ms | 4.491 ms | 1.49× | 1.32× |
| Snailtracer | 20.666 ms | 60.723 ms | 80.553 ms | 35.627 ms | 2.94× | 1.72× |

### AMD EPYC Genoa / Linux x86-64

Historical revm snapshot from a KVM guest pinned to one CPU.

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

## Micro Benchmarks

`zig build micro` runs focused zBench tests for inner-loop work. These are
Zig-only microscope checks for one implementation area, not cross-engine
comparisons:

```sh
cd bench
zig build micro -Dmicro-filter=micro/arithmetic
zig build micro -Dmicro-filter=sdiv
zig build micro -Dmicro-filter=mulmod
zig build micro -Dmicro-filter=sparse-hash-map
zig build micro -Dmicro-filter=sparse-hash-map/storage-slot-contains
zig build micro -Dmicro-filter=overlay/cold-storage-load
```

Micro benchmarks default to `ReleaseFast` even when the sidecar build default is
debug. Use `-Dmicro-optimize=ReleaseSafe` when a checked timing run is useful.
Arithmetic rows batch 256 helper calls. State-map lookup/hash rows batch 1,024
operations, while clear rows batch eight independently prefilled maps. Keep tests
split by function or feature so `-Dmicro-filter` stays precise.

The sparse-map microscope compares the executor's internal `SparseHashMap`
against `std.AutoHashMap` with the same generated keys and preallocation. Lookup
rows batch 1,024 operations per reported zBench run; divide `time/run` by 1,024
for per-operation cost. Clear rows end in `/8x`; divide those by eight. Setup
hooks refill maps outside the timed window. `storage-slot-contains` models the
fused transaction-local `StorageKey -> StorageSlot` map, `storage-overlay-get`
models accepted-overlay `StorageKey -> u256` lookups, `account-get-ptr` uses the real
`Address -> Account` map type, and `clear-retaining-capacity` times only
clearing. `overlay/cold-storage-load` exercises real slot creation, warmth,
journaling, and both accepted-storage hits and misses. Reserve/live counts are part
of each row name. These rows diagnose executor state layout; they are not VM-core
scoreboard rows.

## VM-loop Runners

`zig build vm-loop` implements the simple evm-bench fixture protocol for evmz.
`zig build evmone-vm-loop` is the standalone C++ analyzed evmone runner used by
compare/report. `zig build evm2-vm-loop` runs the same fixtures through
EVM2’s low-level interpreter path:

```sh
cd bench
zig build vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes
zig build evmone-vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes --mode baseline
zig build evm2-vm-loop -- --fixture fixtures/vm-loop/ten-thousand-hashes
zig build vm-loop -- --fixture fixtures/vm-loop/erc20-mint --summary
zig build vm-loop -- --engine evmz --fixture fixtures/vm-loop/erc20-mint --summary
zig build vm-loop -- \
  --engine evmz-executor \
  --fixture fixtures/vm-loop/erc20-transfer-proxy \
  --proxy-target-code-path fixtures/vm-loop/erc20-transfer/init.hex
zig build vm-loop -- \
  --contract-code-path path/to/init-code.hex \
  --call-data 30627b7c \
  --num-runs 5
```

The runner deploys the contract once, then times repeated calls to the returned
runtime bytecode. Stdout contains one millisecond value per run so external
harnesses can consume it. Use `--summary` for host callback counts on stderr.
Before recording runs, every VM-loop engine warms the same prepared execution
path for at least `--warmup-ms 100` by default; pass `--warmup-ms 0` to disable
it. Warmup calls are excluded from timed values and host counts. Summaries and
compare output report `warmup_ms`, `warmup_calls`, and `warmup_elapsed_ms`.
`--fixture` reads `init.hex`, `calldata.hex`, `num-runs.txt`, and
`host-profile.txt` from a fixture directory. CLI flags override fixture defaults.
The [VM-loop fixture guide](fixtures/vm-loop/README.md) documents the LOG0/LOG4
by zero/32-byte data matrix used to separate topic and data-copy costs.
The default evmz runner is direct bound-interpreter `execute()` with
metadata prepared before timing. Use `--engine evmz-executor` only for the
transaction/executor diagnostic stub; it prepares bytecode once and times
`Executor.executePreparedCallTransaction` after transaction setup/reset. The
executor-only `--proxy-target-code-path` deploys a second runtime at
`0x3000000000000000000000000000000000000003`; the proxy fixture above uses it
to measure a real nested ERC call without adding executor work to the VM-core
scoreboard. The standalone evmone runner prepares baseline or advanced analysis
once and times the analyzed execution path.

Host profiles:

- `--host-profile null`: fail after execution if the run touched host callbacks.
  Use this for pure opcode, memory, jump, arithmetic, and keccak benchmarks.
- `--host-profile mock`: provide deterministic in-memory storage/account/log
  callbacks. Use this for VM + mock-host measurements, not pure VM claims.

Every runtime call receives fresh transaction-scoped mock-host state. Storage
slots track value and warmth independently, so the first access to a slot is
cold and later accesses in that call are warm even when the stored value is
zero. Evmz and evmone expose separate access plus get/set callbacks; EVM2’s
low-level host combines those operations, so callback counts remain visible.

Precompiles and real state execution should stay in dedicated kernel or
integration lanes. This layer is intentionally about deployed runtime bytecode
calls. The standalone evmone runner and EVM2 sidecar use small in-memory hosts
for the fixture protocol. The EVM2 runner prepares jump analysis and times
`Interpreter::run()`; transaction validation, finalization and database setup
are outside this lane.

## Block lifecycle runner

`zig build block-lifecycle` measures the normal execution ownership shape for
one block: pre-state is seeded outside timing, then the timed window runs
`Executor` initialization, a `BlockExecution` transaction loop, optional state
persistence, and `Executor.deinit`.
This lane is for integration-level growable-vs-exact policy checks, not VM-core
dispatch comparisons.

```sh
cd bench
zig build block-lifecycle -- --policy growable --txs 1000 --summary
zig build block-lifecycle -- --policy exact-120m --txs 1000 --summary
zig build block-lifecycle -- --case noop --txs 50 --access-list-addresses 256 --summary
zig build block-lifecycle -- --case noop --txs 50 --access-list-storage-keys 256 --summary
```

The default case is `sstore-unique`, where each transaction writes a distinct
storage key through normal transaction execution. Use `--case noop` for lifecycle
overhead or `--case sstore-same` for repeated writes to the same slot. The
synthetic access-list flags model declared resource hints without changing the
fixture protocol: `--access-list-addresses` creates distinct account entries,
while `--access-list-storage-keys` spreads keys across those entries, or uses the
benchmark contract as the single entry when no address count is supplied. Stdout
is CSV:

```text
suite,policy,case,spec,repeat,txs,access_list_addresses,access_list_storage_keys,elapsed_ns,ns_per_tx,gas_used,block_gas_used,tx_count,commit
```

## Opcode kernel runner

`zig build kernel` generates repeated opcode patterns and times only
bound-interpreter `execute()` after bytecode generation and interpreter
initialization. It uses the null host and fails if a case touches host callbacks.
The default comparison mode is native release for the Rust sidecar: Zig uses
`ReleaseFast`, evmone is compiled into the Zig benchmark binary with the same
optimization mode. EVM2 uses Cargo `--release` with
`RUSTFLAGS="-C target-cpu=native -C force-frame-pointers=no"`, fat LTO, and one
codegen unit.

Kernel case bytecode lives in `fixtures/kernel/*.hex`. Both the Zig runner and
the EVM2 sidecar read the same fixture files, then repeat or cycle non-empty
lines to build the requested iteration count. Branch fixtures use repeatable
relative `PC + offset` targets so the same fixture line can be reused at any
bytecode offset.

```sh
cd bench
zig build kernel -- --case mulmod --case addmod --repeats 5 --warmups 1
zig build kernel -- --case push-pop --iterations 1000000 --repeats 3
zig build kernel -- --engine evmz --engine evmone-baseline --engine evmone --case add
zig build evm2-kernel -- --case add --case mulmod
zig build kernel -- --engine evmz --engine evmone-baseline --engine evmone --tier edge --tier branch --iterations 10000
```

CSV columns:

```text
suite,engine,case,repeat,iterations,bytecode_bytes,capture_bytes,bytes_per_iter,elapsed_ns,ns_per_iter,gas_used,host_calls
```

The Zig kernel runner supports `evmz`, `evmone-baseline`, and
`evmone-advanced` (`evmone` is an alias for advanced mode). The `evmz` row
times only bound-interpreter `execute()` after bytecode generation and interpreter
initialization. evmone rows time the EVMC `execute` call.

The EVM2 runner shares `bench/evm2` with the VM-loop runner. It emits the same
CSV columns with engine `evm2-interpreter`, times only `Interpreter::run()` and
reports execution gas directly. Bytecode construction, jump analysis and
interpreter/host initialization are excluded. Cases use the null host and fail
on host callbacks. Stable packed dispatch is the kernel comparison default.
The report rejects kernel bytecode-size or gas mismatches across engines and
any host callbacks before rendering the comparison.

Case tiers:

- `small`: existing straight-line dispatch/opcode kernels.
- `edge`: 256-bit arithmetic operands, signed high-bit operands, and wide EXP.
- `large`: large PUSH data and dense JUMPDEST bytecode.
- `branch`: repeatable relative `JUMP`/`JUMPI` programs.

## Comparison report

`zig build report` runs the VM-loop fixtures and opcode kernels across
evmz/evmone/EVM2. It
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
`ReleaseFast`, and all Rust variants use `cargo +1.96.0 --release` with `target-cpu=native`,
`force-frame-pointers=no`, fat LTO, and one codegen unit.
Reports and checkpoints should stay under ignored `output/`; they are local
measurement artifacts, not source fixtures. Use `--checkpoint <path>` to write
the compact JSON somewhere stable. Use `--baseline <path>` to include
evmz-vs-evmz deltas in the report after an optimization branch.

Generated EEST benchmark fixtures are intentionally not part of this report
lane. The old transaction-shaped runner mixed host, fixture, and precompile
semantics with VM timing, so future EEST benchmark work should first adapt
meaningful cases into the VM-loop protocol or a separate fair block-verdict
lane.
