# evmz EEST sidecar

This package owns the Ethereum Execution Spec Tests runners for `evmz`.

```sh
scripts/fetch-eest-fixtures.sh
EEST_TRACKS="state_tests blockchain_tests_sync" scripts/fetch-eest-fixtures.sh
zig build eest-scope
zig build eest
zig build eest-classify
zig build eest-tx
```

Every runner is a subcommand of one `evmz-eest` binary (`src/main.zig`
dispatching into `src/cmd/`), and each `zig build` step above is an alias for
one of them — `zig build eest` runs `evmz-eest state`. Run `evmz-eest --help`
for the command list. One runner stays a separate executable: `ssz-conformance`
builds without evmz.

The default state-test corpus comes from the authoritative state track in
`eest.lock`. Bare `zig build eest` derives its versioned cache destination and
runs `fixtures/state_tests`.

Every fixture consumer derives its release URL and cache path from that lock.
`zig build fixture-lock-check` rejects copied release tags and destinations.
Corpus manifests, known-failure policy, and generated SSZ provenance stay
explicit because each must be reviewed when its owning corpus changes.

`EEST_TRACKS` limits extraction to named fixture directories. CI restores the
pinned compressed archive from cache, verifies its lockfile SHA-256, and only
materializes `state_tests` plus `blockchain_tests_sync`. Extracted fixtures are
not cached because the state tree alone is roughly 1.5 GB.

The `Execution spec tests` workflow has independent execution-fixture and
consensus-SSZ jobs. The execution job runs the full sidecar tests, state corpus,
and regular BlockSTF corpus with four workers. The SSZ job uses its separately
pinned consensus-spec archives. A third job runs the complete pinned zkEVM
native corpus, tracked-state differential, and mutation matrix. The guest
workflow runs the same 27,184 fixtures on ZisK: 27,162 match,
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

## Stateless zkEVM Fixtures

The `zkevm` runner checks the pinned `tests-zkevm` stateless SSZ contract
directly. It executes each block carrying `statelessInputBytes` and compares the
canonical result with `statelessOutputBytes`:

```sh
scripts/fetch-eest-zkevm-fixtures.sh
zig build zkevm
zig build zkevm -- --report ../.eest/zkevm-report.json
zig build zkevm -- --oracle-differential
zig build zkevm-mutations
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

`--oracle-differential` compares the dense production validator with the
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

## BlockSTF Fixtures

There are two block fixture lanes:

- `eest-block-stf`: regular `blockchain_tests` through `eth.BlockSTF`. This is
  the primary BlockSTF lane and uses regular EEST pre/genesis state through a
  `MemoryStore` state backend.
- `eest-stateless-block-stf`: witness-backed zkEVM `blockchain_tests` through
  `eth.BlockSTF`. This validates the stateless/witness BlockSTF path, not the
  general BlockSTF fixture path.

The stateless adapter targets the `tests-zkevm` fixture track because those
blockchain fixtures include `executionWitness` material. It currently supports
positive genesis-child blocks with empty or legacy-signed payload transactions;
unsupported typed transaction families are reported as explicit skips. With no
explicit path, the CLI runs the supported EIP-7928 block access list directory
from the locked zkEVM fixture cache.

The regular adapter targets the locked Glamsterdam block corpus under
`fixtures/blockchain_tests_sync`. It consumes Engine API `engineNewPayloads` and
`syncPayload` entries in order, seeds fixture `pre` into `MemoryStore`, and only
commits a block into that store after `eth.BlockSTF` validates it. Before
Amsterdam, payload `gasUsed` is checked against cumulative receipt gas. From
Amsterdam onward, it is checked against the execution-derived block/header gas
scalar, which may differ from cumulative receipt gas after refunds and
two-dimensional state-gas accounting.

Transaction and withdrawal roots are currently recorded as local body
recomputes, not standalone consensus claims. `eth.BlockSTF` now reconstructs the
full post-Merge execution header from execution-derived roots and compares its
canonical RLP hash with the fixture's `blockHash`. A valid block's reconstructed
hash, rather than the unchecked payload value, becomes the next block's parent
and `BLOCKHASH` source. Header `gasUsed` is execution-derived for every supported
fork.

Before execution, both fixture lanes also validate parent-derived child-header
rules: consecutive number, strictly increasing timestamp, gas-limit adjustment
bounds, and the EIP-1559 base fee. BlockSTF separately enforces the active
schedule's cumulative blob-gas cap across all transactions in the block. Each
adapter forwards the selected fork entry from `config.blobSchedule`, so both
the cap and blob base fee use fixture chain parameters when supplied.

The stateless adapter performs the same header-hash check from witness-backed
execution outputs. For genesis-child fixtures it also checks parent continuity
against `genesisBlockHeader` and exposes that parent through `BLOCKHASH`.

Expected-invalid blocks remain separate from the positive lane. Audit them
without assigning truth to the fixture exception label with:

```sh
zig build eest-stateless-block-stf -- --expected-exceptions-only path/to/blockchain_tests
```

The audit reports observed BlockSTF rejection statuses, accepted blocks,
adapter errors, and unsupported skips independently. When an invalid fixture
only carries raw `rlp`, the adapter uses its fixture-provided `rlp_decoded` view
alongside the outer `executionWitness`; format-sensitive results from that view
are diagnostic evidence, not a proof that either the fixture label or the
normalized decoding is correct.

```sh
EEST_TRACKS=blockchain_tests_sync scripts/fetch-eest-fixtures.sh
zig build eest-block-stf
zig build eest-block-stf -- --bal-differential

scripts/fetch-eest-zkevm-fixtures.sh
scripts/fetch-eest-zkevm-fixtures.sh --steps
zig build eest-stateless-block-stf
```

The manifest form verifies the same locked archive checksum but extracts only
the representative files used by the manual ZisK execution-step report. That
report is diagnostic: it records guest steps and public-output parity without a
step-regression threshold or any proof-generation work.

`--bal-differential` is a serial diagnostic lane. For each Amsterdam payload
transaction it compares an isolated `BalClaimReader` execution with the
authoritative `BlockSTF` fold. Coverage failures and unsupported transaction
hooks stop the claim lane and leave the authoritative serial result untouched.
Outcome or diagnostic infrastructure failures fail the differential gate. Final
BAL parity promotes matched transaction outcomes to an outcome-and-BAL-evidence
match; mismatches print a bounded, deterministic per-account diff.

The broader Glamsterdam block corpus is still the golden regular source. In the
locked fixture cache it is currently under `fixtures/blockchain_tests_sync`.
Extract it alone with:

```sh
EEST_TRACKS=blockchain_tests_sync scripts/fetch-eest-fixtures.sh
```

Those non-zkEVM fixtures do not carry `executionWitness`, so the stateless
adapter reports them as `missing_execution_witness` if pointed there. The
regular BlockSTF adapter should consume EEST pre/genesis state directly.
