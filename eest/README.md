# Ethereum Conformance (`eest/`)

Runs official `ethereum/execution-specs` (EEST) and `ethereum/consensus-specs`
test suites against `evmz`. Upstream Python tooling (`consume direct`, pinned in
`consume/uv.lock`) owns fixture resolution, caching, selection, and parallel
pytest execution; this package provides the `evmz-eest` and
`evmz-ssz-conformance` runners.

| Suite | Default corpus | Command (from repo root) |
| --- | --- | --- |
| Execution (`state_test`, `blockchain_test`, `transaction_test`) | `tests@v21.0.2` | `zig build -Doptimize=fast eest-consume -- --no-html -n 4` |
| Stateless zkEVM (native BlockSTF + witness oracle) | `tests-zkevm@v21.0.6` | `zig build -Doptimize=fast zkevm-consume -- --no-html -n 4` |
| Resolve zkEVM corpus manifest for guest/mutation lanes | `tests-zkevm@v21.0.6` | `zig build zkevm-resolve` |
| Stateless zkEVM on zkVM guest (`zisk`, `sp1`, `openvm`) | manifest | `zig build zkevm -- --corpus-manifest .zig-cache/eest-consume/zkevm-corpus.json ...` |
| Stateless witness rejection mutations | manifest | `zig build zkevm-mutations -- --corpus-manifest .zig-cache/eest-consume/zkevm-corpus.json` |
| Consensus SSZ (`general`, `mainnet`, `minimal`) | `consensus.zon` | `zig build ssz-conformance` |
| Runner unit tests | local | `zig build eest-test` |

## Direct conformance

`eest-consume` runs released `state_test`, `blockchain_test`, and
`transaction_test` fixtures through `consume direct`:

```sh
zig build -Doptimize=fast eest-consume -- --no-html -n 4
```

The default corpus is `tests@v21.0.2`, pinned in `eest/build.zig`. Override it
with `--input`:

```sh
zig build eest-consume -- --input=tests@latest -k add11
zig build eest-consume -- --input=/path/to/fixtures -m state_test
```

`evmz-eest` is the subprocess boundary invoked by the pytest plugins:

```sh
evmz-eest statetest [--run EXACT_ID] fixture.json
evmz-eest blocktest [--run EXACT_ID] fixture.json
evmz-eest transactiontest [--run EXACT_ID] fixture.json
evmz-eest zkevmtest [--run EXACT_ID] fixture.json
```

Each command emits a JSON list of `{name, pass, skip, error}` records. `--run`
selects one top-level fixture id exactly. Each pytest worker caches one
file-level result so multiple test ids in the same file do not restart `evmz-eest`.

- **State & block fixtures:** A state fixture without a comparable post-state
  assertion fails. A block transaction carrying `expectException` passes only
  when `block.Stf` returns the matching typed transaction rejection; invalid
  blocks require a matching block-level error.
- **Transaction fixtures:** Decode signed bytes through the production raw
  decoder and apply admission checks under neutral account state and default
  chain ID (`1`), comparing either the expected rejection or `(tx_hash, sender, intrinsic_gas)`.
- **Fork scope:** The default marker expression covers all state and transaction
  fixtures plus post-Merge blockchain fixtures from Paris through Amsterdam
  (including BPO1, BPO2, and Amsterdam BPO increase/decrease scenarios).
  Pre-Merge PoW/ommer fixtures and transition-fork fixtures are excluded at the
  pytest selection boundary.

## Stateless zkEVM fixtures

Native stateless conformance uses the same `consume direct` harness against
`tests-zkevm@v21.0.6`:

```sh
zig build -Doptimize=fast zkevm-consume -- --no-html -n 4
```

`zkevmtest` executes every selected block from `statelessInputBytes`, compares
the raw result with `statelessOutputBytes`, and runs the dense-versus-tracked
oracle for valid blocks.

For persistent zkVM guest execution and witness-mutation checks, resolve the
corpus into an explicit JSON manifest first:

```sh
zig build zkevm-resolve
zig build zkevm -- \
  --corpus-manifest .zig-cache/eest-consume/zkevm-corpus.json
zig build zkevm-mutations -- \
  --corpus-manifest .zig-cache/eest-consume/zkevm-corpus.json
```

To resolve a specific `tests-zkevm` version:

```sh
zig build zkevm-resolve -- \
  --input=tests-zkevm@vX.Y.Z \
  --manifest=/tmp/tests-zkevm.json
zig build zkevm -- --corpus-manifest /tmp/tests-zkevm.json
```

The manifest records the resolved release, upstream index root hash, source
commit, indexed test count, stateless block count, and fixture roots.

- **`zkevm` (`--executor zisk|sp1|openvm`):** Keeps one persistent guest-host
  child process per worker so ELF-to-ROM conversion happens once, strips guest
  framing, and checks output against `statelessOutputBytes`. Pass
  `--evidence-dir` for aggregate release evidence and `--output-folder` for
  ERE-compatible `BenchmarkRun` rows.
- **`zkevm-input` / `zkevm-ere`:** Extract raw or guest-framed input from a
  fixture (`zkevm-input`) or run the native ERE adapter on one raw input
  (`zkevm-ere`).
- **`zkevm-mutations`:** Applies structured schema-v1 SSZ witness mutations from
  `fixtures/stateless-mutations-tests-zkevm.txt` and verifies that `block.Stf`
  rejects each with the expected typed status.

CI enforces zero known-failure waivers; unexpected failures, empty runs, I/O
errors, or guest startup failures fail the run.

## Consensus SSZ fixtures

`zig build ssz-conformance` validates `pkg/ssz` against the `general`,
`mainnet`, and `minimal` archives pinned in `consensus.zon` (Phase0 through
Heze):

```sh
zig build ssz-conformance
```

Valid fixtures must decode, re-encode byte-for-byte, and match their expected
`hash_tree_root`; invalid generic fixtures must fail decoding. Static fork
schemas in `src/ssz_static/` are generated from the matching consensus-spec
pyspec release.

Without arguments, `zig build ssz-conformance` extracts the ~5 GB pinned
archives once into `${XDG_CACHE_HOME:-$HOME/.cache}/evmz/consensus/<hash>/`
(serialized by a file lock so worktrees share one read-only cache without
re-extracting). Pass a local fixture path after `--` to test a single file or
directory without resolving the shared cache.

## Ownership summary

| Lane                | Source/orchestration owner        | evmz-owned code                     |
| ------------------- | --------------------------------- | ----------------------------------- |
| State fixtures      | execution-specs `consume direct`  | fixture-to-TransactionSTF adapter   |
| Blockchain fixtures | execution-specs `consume direct`  | fixture-to-BlockSTF adapter         |
| Transaction fixtures | execution-specs `consume direct` | raw decoding and admission checks  |
| zkEVM native corpus | execution-specs `consume direct`  | stateless block adapter and oracle  |
| zkVM guest corpus   | execution-specs resolver manifest | persistent guest executor/evidence  |
| Witness mutations   | execution-specs resolver manifest | bounded semantic mutations          |
| Consensus SSZ       | consensus-spec release archives   | SSZ conformance adapter and schemas |
