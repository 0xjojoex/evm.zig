# evmz EEST adapters

Released `state_test` and `blockchain_test` conformance uses
`ethereum/execution-specs` `consume direct`. That upstream runner owns fixture
releases, discovery, pytest selection, caching, reporting, and parallelism.
`evmz-eest` only owns the file-to-evmz process boundary:

```sh
evmz-eest statetest [--run EXACT_ID] fixture.json
evmz-eest blocktest [--run EXACT_ID] fixture.json
evmz-eest zkevmtest [--run EXACT_ID] fixture.json
```

These commands write a JSON list of `{name, pass, skip, error}` records to
stdout. `--run` selects one top-level EEST id exactly. An unchecked or empty
state/block execution is a failed record, not a successful compatibility
result. A zkEVM blockchain fixture without `statelessInputBytes` is an explicit
pytest skip because it has no input for that adapter. CLI, fixture parsing, and
I/O failures exit nonzero instead of producing a semantic record.

This seam does not turn legacy skips into passes. Regular `blockchain_test`
entries with a transaction `expectException` are decoded from the canonical
block RLP and pass only when BlockSTF returns the matching typed transaction
rejection. An invalid-block expectation remains a failed result unless its
block-level status has an equally precise mapping. State fixtures with no
comparable post-state assertion likewise remain failed. Those are adapter
coverage gaps for the upstream pytest report to expose.

The repo-owned stateful and stateless consumer plugins only translate selected
fixtures to those process boundaries. Each plugin caches the complete result
for one JSON file, so several indexed ids in that file do not restart evmz.
`zig build` builds the binary, creates the pinned uv environment, and hands
recursive discovery and execution to `consume direct`:

```sh
zig build -Doptimize=ReleaseFast eest-consume -- \
  --no-html \
  -n 4
```

The default input is the execution-specs release pinned by `eest.lock`; later
`--input` and pytest arguments override the defaults for local files, exact-id
selection, fork markers, and debugging. The default conformance selection is
all `state_test` fixtures plus exact post-Merge `blockchain_test` forks through
Amsterdam. Pre-Merge blocks require mining rewards and ommer/PoW consensus that
do not belong in evmz BlockSTF, while transition-fork fixtures need a
block-by-block revision adapter. They are excluded at the upstream pytest
selection boundary instead of being reported as evmz passes.

The execution-specs Python packages are pinned in `consume/uv.lock`. There is
no repo-owned state/block/transaction corpus fetcher, recursive runner, worker
pool, classifier, or scope reporter. `evmz-eest` contains only the direct
adapters and the custom zkEVM guest commands. Run `evmz-eest --help` for the
command list. `ssz-conformance` stays a separate executable and builds without
evmz.

Every direct fixture consumer derives its release from `eest.lock`.
`zig build fixture-lock-check` rejects copied release tags and destinations.
Corpus manifests, known-failure policy, and generated SSZ provenance stay
explicit because each must be reviewed when its owning corpus changes.

The `Execution spec tests` workflow has independent execution-fixture and
consensus-SSZ jobs. The execution job invokes consume-direct once with eight
pytest workers; execution-specs owns state/block discovery, filtering,
reporting, and release handling. The SSZ job uses its separately pinned
consensus-spec archives. A third job uses the same consume cache and pytest
machinery for the complete pinned zkEVM native corpus, then runs the custom
mutation matrix. The guest workflow runs the same 27,184 fixtures on ZisK:
27,162 match,
while 22 pinned ZisK alpha BLS12-381 provider crashes remain explicitly tracked;
the strict release gate does not waive them.

## Consensus SSZ Fixtures

The sidecar also hosts consensus-spec SSZ conformance while keeping that fixture
track separate from execution-spec EEST releases:

```sh
scripts/fetch-consensus-ssz-fixtures.sh
zig build ssz-conformance
```

The fetch script finds the `main` worktree by default and extracts only the SSZ
subtrees from the pinned, checksum-verified General, Mainnet, and Minimal
release archives. The runner resolves that same main-worktree cache by default;
`EVMZ_EEST_ROOT` can override it. A bare `ssz-conformance` run covers all three
lanes and fails if no cases run or any case is skipped:

- General: every generic serialization family, including progressive types and
  compatible unions. Valid fixtures must decode, re-encode byte-for-byte, and
  match `meta.yaml`; invalid fixtures must reject.
- Mainnet and Minimal: typed consensus objects from Phase0 through Heze. Each
  canonical static fixture must decode, re-encode byte-for-byte, and match
  `roots.yaml`.

The pinned corpus contains 5,145 General cases, 2,275 Mainnet cases, and 55,965
Minimal cases. Preset/fork schemas are checked-in Zig
declarations under `src/ssz_static/`; fixture YAML is not interpreted as a
runtime schema.
The generator fingerprints named schemas recursively, including collection
limits and progressive active fields, and emits each historical shape once in
the first fork that requires it. Later preset/fork handlers only reference that
registry. The authoring script regenerates the declarations from the matching
resolved consensus-spec pyspec when the pin changes. Canonical `value.yaml`
mapping remains separate from binary and hash-tree-root conformance.

Regeneration uses the Python environment from the exact pinned consensus-specs
checkout. With `EVMZ` set to this repository:

```sh
source scripts/eest-lock.sh
CONSENSUS_REPO="$(eest_lock_value consensus_repo)"
CONSENSUS_RELEASE="$(eest_lock_value consensus_release)"
FIXTURES="$(eest_release_path consensus "$CONSENSUS_RELEASE")"
git clone --depth 1 --branch "$CONSENSUS_RELEASE" \
  "https://github.com/${CONSENSUS_REPO}.git" /tmp/evmz-consensus-specs
(cd /tmp/evmz-consensus-specs && make _pyspec)
(cd /tmp/evmz-consensus-specs && uv run python \
  "$EVMZ/eest/scripts/generate-consensus-ssz-schemas.py" \
  --pyspec-root tests/core/pyspec \
  --fixtures-root "$FIXTURES" \
  --version "$CONSENSUS_RELEASE" \
  --output "$EVMZ/eest/src/ssz_static")
```

Benchmark fixtures are a separate EEST release track and can be cached for
future adapter work:

```sh
scripts/fetch-eest-benchmarks.sh
```

There is no active EEST benchmark runner. Routine engine comparisons live in
`bench/` and use VM-loop fixtures; EEST benchmark cases should be adapted into
that protocol or a separate fair block-verdict lane before being reported.

## Stateless zkEVM fixtures

Native conformance uses the pinned `tests-zkevm` release through
execution-specs. `consume cache` owns release resolution and extraction, while
`consume direct` owns indexing, selection, reporting, and parallelism. The
small `zkevmtest` adapter executes each selected block carrying
`statelessInputBytes` and compares the canonical result with
`statelessOutputBytes`:

```sh
zig build zkevm-cache
zig build -Doptimize=ReleaseFast zkevm-consume -- --no-html -n 4
zig build zkevm-mutations
```

The direct adapter always runs the dense-versus-tracked oracle comparison for
valid native blocks. It calls the same `stateless.runCase` implementation as
the guest runner, so fixture semantics have one owner. The pinned release has
25,100 indexed `blockchain_test` ids: 23,994 contain stateless inputs and 1,106
ordinary blockchain fixtures are reported as upstream-visible skips. Those
23,994 ids contain 27,184 stateless blocks in total.

The custom `zkevm` command remains for zkVM process lifetime, diagnostic
reports, and release evidence:

```sh
scripts/fetch-eest-zkevm-fixtures.sh
zig build zkevm -- --executor zisk --zisk-host PATH --zisk-elf PATH
zig build zkevm -- --report ../.eest/zkevm-report.json
```

The ERE adapter uses the same raw SSZ output as the fixture and upstream guest
programs. `zkevm-input` extracts raw input or ZisK-framed stdin together with
the expected public output, and `zkevm-ere` runs the native adapter on one
input. ZisK framing pads the raw result to 256 bytes without hashing it.

`zkevm --executor zisk|sp1` runs each block's `statelessInputBytes` on a zkVM
guest instead of natively. The executor strips guest framing before comparison,
so every executor is judged against the same `statelessOutputBytes` and one set
of fixture semantics — `expectException`, malformed-input handling, the report
categories — covers all three. Add `--output-folder` to emit one ERE
`BenchmarkRun` row per block. CI instead uses `--evidence-dir`, which owns its
`rows/` directory and writes the aggregate `evidence.json` and `report.md` in
the same `zkevm` process.

A guest writes into a fixed-width public region and an encoded
`StatelessValidationResult` is variable-size, so the meaningful length cannot be
recovered from the region alone; the executor takes it from the fixture's own
expected output and requires the remainder of the region to be zero. A guest
that fails before producing a result returns a nonzero exit status, which the
host reports as a crash rather than as a wrong output.

Guest runs share one session across every root, so a guest host child converts
the ELF to a ROM once per worker rather than once per corpus batch. Each worker owns one host child process, and
that child converts the guest ELF to a ZisK ROM once at startup — roughly 0.4s,
against ~10ms of execution for a typical fixture — so `--jobs N` pays that setup
N times and then amortises it across every fixture the worker handles.

`fixtures/guest-known-failures.json` records corpus-scoped failures expected on
a pinned backend, with the upstream cause. Evidence mode annotates them and
fails if any entry passes or disappears from its declared corpus. Diagnostic
and strict evidence may retain exact known failures; strict mode additionally
requires pinned release-corpus identity. A backend upgrade that fixes one
therefore forces its removal rather than letting the list rot. Unexpected
failures, configuration, I/O and host-startup failures still fail immediately,
as does an empty run.

`--report` selects a serial run and writes deterministic JSON with one record
per runnable block. Records include revision, fixture family, validation status,
first differing result field, and a broad ownership category. The command still
exits nonzero for any mismatch; the report is diagnostic input for closing the
baseline, not a waiver for known failures. Blocks without stateless input are
reported as skips in the terminal summary and are not conformance records.

The direct native lane compares the dense production validator with the
tracked-state oracle for every block without `expectException`. The comparison
covers every consensus-derived `BlockSTF.Result` field, including status,
roots, gas accounting, logs bloom, requests, and BAL hash. It excludes only
`tx_index`: dense admission can reject before a transaction starts while the
tracked oracle discovers the same invalid witness during that transaction.
Blocks carrying `expectException` are excluded because they can contain
several independent faults and do not define an internal rejection priority;
the typed mutation matrix owns failure-status parity.

`zkevm-mutations` is the separate adversarial gate. It starts from a bounded
manifest of canonical inputs from the pinned zkEVM corpus that validate
successfully, applies structured mutations, re-encodes and decodes valid
schema-v1 SSZ, then requires the intended typed `BlockSTF.Status`. It covers
missing and altered trie nodes, code, authenticated headers and pre-state roots,
public keys, explicit payload claims, BAL coverage, withdrawals, transaction
bodies, and all five Amsterdam request families. BAL coverage includes omitted
accounts and storage slots as well as spurious accounts and storage reads.

The gate is an existence proof, not a coverage proof: a mutation resolves on
the first variant that reaches its expected status, so it shows each rejection
path is live, not that every witness element is checked. Node, code, and header
variants are capped at 128 per input to bound runtime; a mutation that no
variant resolves fails the gate.

Transaction and withdrawal roots are implicit in the wire's block-hash claim
rather than independent fields, so mutating a withdrawal body requires
`block_hash_mismatch`. The gate does not present either as an independent root
claim. Altered transaction bytes are rejected earlier by authenticated
public-key validation, which EIP-8025 requires: the corpus carries
`witness_public_keys` fixtures where an invalid or opposite-parity key must
make an otherwise valid block fail, so the hint cannot be ignored.

For a mutation-only checkout, the same bounded manifest can drive extraction:

```sh
scripts/fetch-eest-zkevm-fixtures.sh \
  --mutations
zig build zkevm-mutations
```

## BlockSTF fixture boundaries

Regular `blockchain_test` conformance enters through `blocktest` under
`consume direct`. The adapter decodes canonical block RLP, seeds EEST `pre`
state, invokes `eth.BlockSTF`, and maps the resulting evmz status to the EEST
exception taxonomy. It does not own discovery or corpus execution.

Native zkEVM conformance enters through `zkevmtest` under the same upstream
runner. The custom `zkevm` command remains only for guest process lifetime,
release evidence, and backend-specific diagnostics. `zkevm-mutations` owns the
bounded adversarial status checks. There is no second general BlockSTF fixture
runner.
