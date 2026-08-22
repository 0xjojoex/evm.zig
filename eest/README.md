# evmz Ethereum fixture adapters

Execution fixtures come from `ethereum/execution-specs`. Its Python tooling
owns release resolution, downloads, caching, indexing, recursive discovery,
pytest selection, parallelism, and reports. This repository owns only the
evmz-specific execution seams.

## Direct conformance

Released `state_test` and `blockchain_test` conformance runs through `consume
direct`:

```sh
zig build -Doptimize=ReleaseFast eest-consume -- --no-html -n 4
```

The default source is `tests-glamsterdam-devnet@latest`. Pass another upstream
release selector or a local fixture directory with `--input`:

```sh
zig build eest-consume -- --input=tests@latest -k add11
zig build eest-consume -- --input=/path/to/fixtures -m state_test
```

The execution-specs packages are pinned in `consume/uv.lock`; fixture releases
are not pinned in this repository. `@latest` is resolved by execution-specs,
and CI records the exact resolved release where evidence needs an immutable
corpus identity.

`evmz-eest` provides the deliberately small process boundary consumed by the
pytest plugins:

```sh
evmz-eest statetest [--run EXACT_ID] fixture.json
evmz-eest blocktest [--run EXACT_ID] fixture.json
evmz-eest zkevmtest [--run EXACT_ID] fixture.json
```

Each command emits a JSON list of `{name, pass, skip, error}` records. `--run`
selects one top-level fixture id exactly. Each pytest worker caches one complete
file-level result, so indexed ids assigned to that worker do not restart evmz.

The adapter does not turn missing semantics into success. A state fixture with
no comparable post-state assertion fails. A regular block transaction carrying
`expectException` passes only when BlockSTF returns the matching typed
transaction rejection. Invalid-block exceptions require an equally precise
block-level mapping. Upstream pytest output exposes any remaining adapter gaps.

The default marker expression covers all state fixtures plus post-Merge
blockchain fixtures through Amsterdam. Pre-Merge reward, ommer, and PoW rules
do not belong in BlockSTF. Transition-fork fixtures require a block-by-block
revision adapter. Both are excluded at the upstream selection boundary.

There is no repository-owned execution-fixture downloader, general recursive
runner, worker pool, classifier, or scope reporter.

## Stateless zkEVM fixtures

Native stateless conformance uses the same upstream machinery:

```sh
zig build -Doptimize=ReleaseFast zkevm-consume -- --no-html -n 4
```

`zkevmtest` executes every selected block with `statelessInputBytes`, compares
the raw result with `statelessOutputBytes`, and runs the dense-versus-tracked
oracle for valid blocks. A blockchain fixture without stateless input is an
upstream-visible pytest skip.

The custom guest and adversarial lanes need a persistent zkVM process and
evmz-specific mutation semantics. They still use execution-specs as their only
corpus source. `zkevm-resolve` asks the upstream `FixturesSource` implementation
to resolve/cache the release and writes an explicit manifest for Zig:

```sh
zig build zkevm-resolve
zig build zkevm -- \
  --corpus-manifest .zig-cache/eest-consume/zkevm-corpus.json
zig build zkevm-mutations -- \
  --corpus-manifest .zig-cache/eest-consume/zkevm-corpus.json
```

For an exact corpus:

```sh
zig build zkevm-resolve -- \
  --input=tests-zkevm@v0.8.2 \
  --manifest=/tmp/tests-zkevm.json
zig build zkevm -- --corpus-manifest /tmp/tests-zkevm.json
```

The generated manifest records the exact resolved release, upstream index root
hash, source commit, indexed test count, stateless block count, and resolved
fixture roots. Zig never infers execution-specs cache layout and has no fallback
to a repository cache or lock.

The custom `zkevm` runner remains because each worker owns one guest-host child
and converts the ELF to a ROM once. Per-fixture pytest subprocesses would repay
that setup for every case. Native conformance does not use this runner.

`zkevm --executor zisk|sp1` strips guest framing before comparing the result,
so every executor is judged against the same `statelessOutputBytes`. Use
`--evidence-dir` for aggregate evidence and `--output-folder` for ERE-compatible
`BenchmarkRun` rows. `zkevm-input` extracts raw input or guest-framed stdin;
`zkevm-ere` runs the native ERE adapter on one raw input.

CI has no known-failure waiver. Unexpected failures, empty runs, I/O errors,
and guest startup failures always fail. Strict evidence also requires an exact
release and index hash.

`zkevm-mutations` starts from the bounded paths in
`fixtures/stateless-mutations-tests-zkevm-v0.8.2.txt`, applies structured
schema-v1 SSZ mutations, and requires the intended typed BlockSTF status. This
is an evmz-specific existence gate for witness rejection paths, not a second
general fixture consumer or a coverage proof.

## Consensus SSZ fixtures

Consensus SSZ is not an execution-spec fixture format. It retains a separate,
checksum-bearing pin in `consensus.lock` and a consensus-owned cache:

```sh
eest/scripts/fetch-consensus-ssz-fixtures.sh
zig build ssz-conformance
zig build consensus-lock-check
```

The fetcher extracts only the General, Mainnet, and Minimal SSZ subtrees from
the pinned consensus-spec release. By default the cache lives in the main
worktree at `eest/.consensus`; `EVMZ_CONSENSUS_ROOT` overrides it. A bare
conformance run covers all three presets and fails on an empty, skipped, or
failed case.

General fixtures validate generic serialization types. Mainnet and Minimal
fixtures validate typed consensus objects from Phase0 through Heze. Valid
fixtures must decode, re-encode byte-for-byte, and match their expected root;
invalid generic fixtures must reject.

Static preset/fork schemas are generated into `src/ssz_static/` from the
matching resolved consensus-spec pyspec. Their source release is checked
against `consensus.lock`; this lock has no role in execution fixtures.

## Ownership summary

| Lane | Source/orchestration owner | evmz-owned code |
| --- | --- | --- |
| State fixtures | execution-specs `consume direct` | fixture-to-TransactionSTF adapter |
| Blockchain fixtures | execution-specs `consume direct` | fixture-to-BlockSTF adapter |
| zkEVM native corpus | execution-specs `consume direct` | stateless block adapter and oracle |
| zkVM guest corpus | execution-specs resolver manifest | persistent guest executor/evidence |
| Witness mutations | execution-specs resolver manifest | bounded semantic mutations |
| Consensus SSZ | consensus-spec release archives | SSZ conformance adapter and schemas |

BlockSTF owns execution ordering and typed engine errors. The EEST adapter owns
only fixture decoding and mapping those typed results to EEST exception names.
