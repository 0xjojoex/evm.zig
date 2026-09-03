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

The default source is pinned in `eest/build.zig` . Pass another
upstream release selector or a local fixture directory with `--input`:

```sh
zig build eest-consume -- --input=tests@latest -k add11
zig build eest-consume -- --input=/path/to/fixtures -m state_test
```

The execution-specs packages are pinned in `consume/uv.lock`, and the default
execution and zkEVM fixture releases are pinned in `eest/build.zig`. Callers can
still request `@latest` explicitly for a rolling diagnostic; CI evidence uses
the repository defaults and records the resolved corpus identity.

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

Direct conformance has no repository-owned execution-fixture downloader,
general recursive runner, worker pool, classifier, or scope reporter.

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
evmz-specific mutation semantics. Release qualification and mutations use
execution-specs as their corpus source. `zkevm-resolve` asks the upstream
`FixturesSource` implementation to resolve/cache the release and writes an
explicit manifest for Zig:

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
  --input=tests-zkevm@v0.8.3 \
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

`zkevm --executor zisk|sp1|openvm` strips guest framing before comparing the
result, so every executor is judged against the same `statelessOutputBytes`. Use
`--evidence-dir` for aggregate evidence and `--output-folder` for ERE-compatible
`BenchmarkRun` rows. `zkevm-input` extracts raw input or guest-framed stdin;
`zkevm-ere` runs the native ERE adapter on one raw input.

CI has no known-failure waiver. Unexpected failures, empty runs, I/O errors,
and guest startup failures always fail. Strict evidence also requires an exact
release and index hash.

`zkevm-mutations` starts from the bounded paths in
`fixtures/stateless-mutations-tests-zkevm-v0.8.3.txt`, applies structured
schema-v1 SSZ mutations, and requires the intended typed BlockSTF status. This
is an evmz-specific existence gate for witness rejection paths, not a second
general fixture consumer or a coverage proof.

## Consensus SSZ fixtures

Consensus SSZ is not an execution-spec fixture format. The EEST Zig package
pins the General, Mainnet, and Minimal archives as lazy data dependencies in
`build.zig.zon`:

```sh
zig build ssz-conformance
```

Zig downloads, verifies, extracts, and caches those packages. A bare
conformance run covers all three presets and fails on an empty, skipped, or
failed case. Passing a fixture path after `--` runs only that local subtree or
file and does not resolve the pinned archives.

General fixtures validate generic serialization types. Mainnet and Minimal
fixtures validate typed consensus objects from Phase0 through Heze. Valid
fixtures must decode, re-encode byte-for-byte, and match their expected root;
invalid generic fixtures must reject.

Static preset/fork schemas are generated into `src/ssz_static/` from the
matching resolved consensus-spec pyspec. The generated index records their
source release, which must match the archive release in
`build.zig.zon`.

## Ownership summary

| Lane                | Source/orchestration owner        | evmz-owned code                     |
| ------------------- | --------------------------------- | ----------------------------------- |
| State fixtures      | execution-specs `consume direct`  | fixture-to-TransactionSTF adapter   |
| Blockchain fixtures | execution-specs `consume direct`  | fixture-to-BlockSTF adapter         |
| zkEVM native corpus | execution-specs `consume direct`  | stateless block adapter and oracle  |
| zkVM guest corpus   | execution-specs resolver manifest | persistent guest executor/evidence  |
| Witness mutations   | execution-specs resolver manifest | bounded semantic mutations          |
| Consensus SSZ       | consensus-spec release archives   | SSZ conformance adapter and schemas |

BlockSTF owns execution ordering and typed engine errors. The EEST adapter owns
only fixture decoding and mapping those typed results to EEST exception names.
