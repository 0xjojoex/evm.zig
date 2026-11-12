# evm.zig Benchmark Lab

Measurement harnesses for `evmz` interpreter dispatch, opcode kernels, block
lifecycle, and inner-loop data structures.

| Lane | Root command | `bench/` command | What it measures |
| --- | --- | --- | --- |
| Cross-engine VM scoreboard | `zig build bench-compare` | `zig build compare` | `evmz` vs `evmone` (baseline/advanced) vs `evm2` on deployed runtime bytecode |
| Full comparison report | `zig build bench-report` | `zig build report` | Runs `compare` + `kernel`, writes Markdown report and `evmz-checkpoint.json` |
| Single-engine VM loop | `zig build bench-vm-loop` | `zig build vm-loop` | Per-call runtime timing for `evmz` (`evmone-vm-loop` and `evm2-vm-loop` for peers) |
| Opcode kernels | `zig build bench-kernel` | `zig build kernel` | Pure opcode loops on the null host (`small`, `edge`, `large`, `branch`) |
| Block lifecycle | `zig build bench-block-lifecycle` | `zig build block-lifecycle` | `Executor` init, `BlockExecution` tx loop, and state persistence (`growable` vs `exact`) |
| Transaction loop | `zig build bench-tx-loop` | `zig build tx-loop` | One complete transaction per call on a long-lived VM (`evm2-tx-loop` and `evmone-tx-loop` for peers) |
| Cross-engine transaction scoreboard | `zig build bench-tx-loop-compare` | `zig build tx-loop-compare` | The transaction loop on `evmz` and `evm2` (`evmone` on request), with a gas cross-check |
| Inner-loop microbench | `zig build bench-micro` | `zig build micro` | zBench microbenchmarks (`arithmetic`, `sdiv`, `mulmod`, `sparse-hash-map`, `overlay`) |
| Code analysis | `zig build bench-code-analysis` | `zig build code-analysis` | Bytecode jumpdest analysis timing and morphology |

## Published snapshots

The current Apple M1 Max snapshot is fixed Amsterdam and uses EVM2 stable
packed dispatch. The AMD snapshot is fixed Osaka and retains its historical
revm baseline. Both are native `ReleaseFast`, with frame pointers omitted for
every engine. Lower is better; ratios above `1.00×` mean evmz is faster than
the named baseline.

### Apple M1 Max / macOS arm64 — 2026-11-12

Evmz explicitly selects the XKCP Keccak provider. Evmone is master revision
`6fb712f3035cb2aa29e810728f11dfb3d786b81e` (reports v0.25.0, EVMC 19), with
intx v0.15.0. EVM2 uses Rust 1.96.0, packed dispatch and revision
`66687c18b34d3bdbb899f5eb7605070615c03475`, pinned to Reth v2.11.0. Rust uses
native CPU tuning, fat LTO and one codegen unit.

Each cell is the median of five 100-call medians per deployed-runtime fixture,
with a 100 ms discarded warmup before each fixture/engine run. Engine order
rotates between rounds. These are interpreter-level measurements with the
fixture's null or mock host. Deployment, bytecode preparation and runner-owned
per-call setup are outside timing. Evmone baseline's analyzed-execute entry
includes its internal execution-state reset.

From the repository root, run this command five times with a distinct
`--out-dir`; rotate engine order with repeated `--engine` filters. Aggregate each fixture/engine's `median_ms`
from the five `summary.csv` files:

```sh
zig build bench-compare -Dbench-optimize=fast \
  -Dbench-support-min=amsterdam -Dbench-support-max=amsterdam \
  -Dnative-keccak=xkcp \
  -- --spec amsterdam --num-runs 100 --warmup-ms 100 \
  --out-dir ../output/readme-amsterdam-20261112/round-1
```

| VM-loop fixture | evmz | evmone-base | evmone-adv | EVM2 packed | base/evmz | EVM2/evmz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Arithmetic loop | 0.092 ms | 0.094 ms | 0.327 ms | 0.232 ms | 1.03× | 2.52× |
| Memory MSTORE loop | 0.090 ms | 0.092 ms | 0.256 ms | 0.175 ms | 1.02× | 1.94× |
| Keccak loop | 2.682 ms | 2.644 ms | 2.570 ms | 2.616 ms | 0.99× | 0.98× |
| Ten-thousand hashes | 0.815 ms | 0.743 ms | 1.634 ms | 1.712 ms | 0.91× | 2.10× |
| Storage SLOAD loop | 0.152 ms | 0.329 ms | 0.374 ms | 0.457 ms | 2.16× | 3.00× |
| Storage SSTORE loop | 0.168 ms | 0.589 ms | 0.630 ms | 0.932 ms | 3.52× | 5.57× |
| LOG0 / 0-byte data | 0.039 ms | 0.030 ms | 0.081 ms | 0.085 ms | 0.76× | 2.19× |
| LOG0 / 32-byte data | 0.064 ms | 0.033 ms | 0.080 ms | 0.089 ms | 0.51× | 1.39× |
| LOG4 / 0-byte data | 0.079 ms | 0.069 ms | 0.148 ms | 0.107 ms | 0.87× | 1.36× |
| LOG4 / 32-byte data | 0.078 ms | 0.075 ms | 0.149 ms | 0.110 ms | 0.96× | 1.42× |
| ERC20 mint | 1.748 ms | 2.650 ms | 3.553 ms | 3.811 ms | 1.52× | 2.18× |
| ERC20 transfer | 3.766 ms | 4.370 ms | 5.601 ms | 5.987 ms | 1.16× | 1.59× |
| ERC20 approval+transfer | 3.478 ms | 3.608 ms | 4.583 ms | 4.549 ms | 1.04× | 1.31× |
| Snailtracer | 20.402 ms | 47.854 ms | 68.301 ms | 35.014 ms | 2.35× | 1.72× |

The transaction loop times one complete transaction per call, so it includes
the fixed per-transaction cost that the VM-loop lane leaves out. Each cell is
the median of 20 batches of 200,000 transactions after one untimed batch, from
one run of:

```sh
zig build bench-tx-loop-compare -Dbench-optimize=fast \
  -- --spec amsterdam --txs 200000 --repeats 20
```

| Transaction | Gas | evmz | evmz, no code cache | EVM2 packed | EVM2/evmz |
| --- | ---: | ---: | ---: | ---: | ---: |
| ETH transfer | 21,000 | 484 ns | 481 ns | 595 ns | 1.23× |
| Call to `STOP` | 15,000 | 457 ns | 492 ns | 539 ns | 1.18× |
| ERC20 transfer | 42,488 | 1,479 ns | 2,039 ns | 1,892 ns | 1.28× |

Evmone is left out of this table because its transaction entry point times
more work; see [Transaction loop runner](#transaction-loop-runner).

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

## Cross-engine VM comparison (`compare`)

`zig build compare` (or `zig build bench-compare` from the repository root)
runs each engine through its interpreter-level entry point: `evmz` through
bound-interpreter `execute()`, `evmone` baseline and advanced through a
standalone C++ runner with bytecode analysis prepared once, and `EVM2` through
a Rust sidecar with prepared bytecode:

```sh
cd bench
zig build compare
zig build compare -- --fixture fixtures/vm-loop/erc20-transfer
```

Raw stdout/stderr plus `summary.csv` and `summary.json` are written under
ignored `zig-out/compare/`. Native builds default to XKCP Keccak on supported
architectures (pass `-Dnative-keccak=std` or `--native-keccak std` to use
`std`). All engines default to `--spec amsterdam` and omit frame pointers
(`-fomit-frame-pointer` for C++, `-C force-frame-pointers=no` for Rust).
Stable Rust rows use the pinned `1.96.0` toolchain (`rustup toolchain install 1.96.0 --profile minimal`),
native CPU tuning, fat LTO, and one codegen unit.

Filter engines with repeated `--engine` flags (`--engine evmz`, `--engine evmone`
for both baseline and advanced, `--engine evm2` for `evm2-interpreter`):

| Engine             | Level                         | Prepared outside timing                                                                           | Timed window                                    | Transaction/overlay work |
| ------------------ | ----------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ------------------------ |
| `evmz`             | exact-spec tail interpreter   | fixture loading, init-code deployment, frame/interpreter setup, jumpdest metadata preparation     | bound-interpreter `execute()`                   | no                       |
| `evmone-baseline`  | analyzed baseline interpreter | fixture loading, init-code deployment through EVMC, `baseline::analyze`                           | `baseline::execute` over `CodeAnalysis`         | no                       |
| `evmone-advanced`  | analyzed advanced interpreter | fixture loading, init-code deployment through EVMC, `advanced::analyze`                           | `advanced::execute` over `AdvancedCodeAnalysis` | no                       |
| `evm2-interpreter` | packed interpreter loop       | fixture loading, init-code deployment, forced jump analysis; per-run interpreter/host setup | `Interpreter::run` | no |

Evmone is pinned to `6fb712f3035cb2aa29e810728f11dfb3d786b81e`, 28 commits
after v0.25.0, and still reports version 0.25.0. EVM2 is pinned to
`66687c18b34d3bdbb899f5eb7605070615c03475` (Reth v2.11.0) with
`EVM2_DISPATCH_BACKEND=packed`. The published snapshots above predate both pins. Each EVM2 variant emits an untimed reference
call's gas used, deployed-code hash, and return-output hash; `compare` rejects
any mismatch across rows.

```sh
zig build compare -- --engine evmz --engine evm2 --num-runs 100 --warmup-ms 100
zig build evm2-vm-loop -- --fixture fixtures/vm-loop/erc20-transfer --summary
cargo +1.96.0 test --locked --manifest-path evm2/Cargo.toml
```

Opt-in nightly EVM2 rows (`evm2-tail` with `EVM2_DISPATCH_BACKEND=tco` and
`evm2-packed-nightly` on `nightly-2026-06-01`) isolate tail-call dispatch from
compiler version differences:

```sh
rustup toolchain install nightly-2026-06-01 --profile minimal
zig build compare -- --engine evmz --engine evm2 \
  --engine evm2-packed-nightly --engine evm2-tail
zig build evm2-tail-vm-loop -- --fixture fixtures/vm-loop/arithmetic-loop --summary
zig build report -- --evm2-nightly
```

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

Micro benchmarks default to `fast` even when the sidecar build default is
debug. Use `-Dmicro-optimize=safe` when a checked timing run is useful.
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

## Transaction loop runner

`zig build tx-loop` times one complete legacy transaction per call on a VM that
lives for the whole run: validation, fee debit, nonce advance, the top-level
call, refund, coinbase payment, and acceptance of the state transition. The
VM-loop lane starts from a prepared call frame and cannot show this fixed cost.
`zig build evm2-tx-loop` runs the same workloads through EVM2's `Evm::transact`
and `ExecutedTx::commit`. `zig build evmone-tx-loop` runs them through evmone's
baseline interpreter under `test::transition`, the transaction entry point of
evmone's state-test tooling.

```sh
cd bench
zig build tx-loop -- --case eth-transfer --txs 200000 --summary
zig build evm2-tx-loop -- --case eth-transfer --txs 200000 --summary
zig build evmone-tx-loop -- --case eth-transfer --txs 200000 --summary
zig build tx-loop -- --case erc20-transfer --txs 200000 --no-code-cache
```

| Case | Transaction |
| --- | --- |
| `eth-transfer` | 1 wei to an existing codeless account |
| `stop-call` | Zero-value call to a contract whose runtime is `STOP` |
| `erc20-transfer` | `transfer(address,uint256)` on the `erc20-transfer` fixture, both balance slots non-zero |

All runners deploy the contracts and prime the state through transactions
before timing, pay a 10 wei gas price over a 7 wei base fee to a non-zero
coinbase, and keep state in the engine's own in-memory store. Each runner fails
unless every timed transaction succeeds with the gas of the steady-state
reference transaction and the recipient ends with the expected balance; equal
`gas_per_tx` across engines is the cross-check that they ran the same work.

EVM2 keeps jump analysis inside its committed bytecode. `evmz` keeps prepared
code in a pool, which block execution installs by default and this runner
installs too; `--no-code-cache` removes it and prepares the callee's code on
every transaction.

The evmone row is not like-for-like on transactions that emit a log. Evmone's
transition also builds the receipt's logs bloom, four Keccak-256 calls for a
log with three topics, which `evmz` and EVM2 leave to their block layer and
this lane does not time. Both transfer cases emit such a log: the ERC20
`Transfer` event, and from Amsterdam the EIP-7708 log of the ETH transfer.

`zig build tx-loop-compare` runs every case on `evmz`, with and without its
code cache, and on EVM2, and fails when `gas_per_tx` differs between engines on
a case. Evmone is off by default for the reason above; name it with
`--engine evmone` to add its row. It writes the per-batch `rows.csv`, the
per-engine medians in `summary.csv` and `summary.md`, and each runner's raw
output under ignored `zig-out/tx-loop-compare/`. The `Benchmark` workflow runs
it as a second job next to the VM-loop comparison; there the `engines` input
`all` means the same default, and evmone runs only when the input names it.

```sh
cd bench
zig build tx-loop-compare
zig build tx-loop-compare -- --case stop-call --engine evmz --engine evmone --repeats 20
```

Evmone ships no block executor, so its row measures the state-test harness, not
a production path. Every transaction builds a fresh `state::State` over a
`std::map` world state, copies the callee's code out of it, analyzes that code,
computes the receipt's log bloom, and applies a `StateDiff`; the row always
reports `code_cache=false`. Compare its contract cases with `evmz
--no-code-cache`. The runner links evmone's precompiles except the blst-backed
BLS12-381 and KZG ones, which abort if a workload calls them.

Stdout is CSV:

```text
suite,engine,case,spec,code_cache,repeat,txs,elapsed_ns,ns_per_tx,gas_per_tx
```

## Opcode kernel runner

`zig build kernel` generates repeated opcode patterns and times only
bound-interpreter `execute()` after bytecode generation and interpreter
initialization. It uses the null host and fails if a case touches host callbacks.
The default comparison mode is native release for the Rust sidecar: Zig uses
`fast`, evmone is compiled into the Zig benchmark binary with the same
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
`fast`, and all Rust variants use `cargo +1.96.0 --release` with `target-cpu=native`,
`force-frame-pointers=no`, fat LTO, and one codegen unit.
Reports and checkpoints stay under ignored `output/`. Use `--checkpoint <path>`
to write the compact JSON to a stable path, and `--baseline <path>` to include
evmz-vs-evmz deltas after an optimization change.
