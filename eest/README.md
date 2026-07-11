# evmz EEST sidecar

This package owns the Ethereum Execution Spec Tests runners for `evmz`.

```sh
scripts/fetch-eest-fixtures.sh
zig build eest-scope
zig build eest
zig build eest -- ../.eest/fixtures/tests-glamsterdam-devnet-v6.1.0/fixtures/state_tests/path/to/test.json
zig build eest-classify
zig build eest-tx
```

The default state-test corpus comes from `eest.lock`, currently
`tests-glamsterdam-devnet@v6.1.0` from `ethereum/execution-specs` for Amsterdam
work. Bare `zig build eest` resolves `eest.lock` `dest` and runs
`fixtures/state_tests`.

Benchmark fixtures are a separate EEST release track and can be cached for
future adapter work:

```sh
scripts/fetch-eest-benchmarks.sh
```

There is no active EEST benchmark runner. Routine engine comparisons live in
`bench/` and use VM-loop fixtures; EEST benchmark cases should be adapted into
that protocol or a separate fair block-verdict lane before being reported.

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
commits a block into that store after `eth.BlockSTF` validates it. Amsterdam
payload `gasUsed` is not asserted yet: the current gas model derives the fixture
receipt root but reports a different scalar. Those blocks remain passing for
the supported checks but are also reported as `unchecked.amsterdam_gas_used`.

Transaction and withdrawal roots are currently recorded as local body
recomputes, not standalone consensus claims. `eth.BlockSTF` now reconstructs the
full post-Merge execution header from execution-derived roots and compares its
canonical RLP hash with the fixture's `blockHash`. A valid block's reconstructed
hash, rather than the unchecked payload value, becomes the next block's parent
and `BLOCKHASH` source. Amsterdam header reconstruction temporarily uses the
payload gas scalar, matching the explicit unchecked result above.

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
EEST_PRUNE_OUT_OF_SCOPE=0 scripts/fetch-eest-fixtures.sh
zig build eest-block-stf -- ../.eest/fixtures/tests-glamsterdam-devnet-v6.1.0/fixtures/blockchain_tests_sync

scripts/fetch-eest-zkevm-fixtures.sh
zig build eest-stateless-block-stf -- ../.eest/fixtures/tests-zkevm-v0.5.0/fixtures/blockchain_tests/for_amsterdam/amsterdam/eip7928_block_level_access_lists/block_access_lists/bal_empty_block_no_coinbase.json
```

The broader Glamsterdam block corpus is still the golden regular source. In the
locked fixture cache it is currently under `fixtures/blockchain_tests_sync`, and
the default fetch prunes it. Preserve it for inspection with:

```sh
EEST_PRUNE_OUT_OF_SCOPE=0 scripts/fetch-eest-fixtures.sh
```

Those non-zkEVM fixtures do not carry `executionWitness`, so the stateless
adapter reports them as `missing_execution_witness` if pointed there. The
regular BlockSTF adapter should consume EEST pre/genesis state directly.
