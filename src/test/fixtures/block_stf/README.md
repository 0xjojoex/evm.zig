# Block STF semantic fixtures

`cases.json` is an API-neutral conformance corpus for the future `eth.BlockSTF`.
It describes protocol behavior rather than the concrete Zig types from the branch
that owns `BlockSTF`.

The corpus targets three boundaries:

1. Block lifecycle: pre-execution hooks, transactions, withdrawals, post-block
   system calls, request derivation, commitments, and atomic commit.
2. EIP-7928 BAL semantics: access-only accounts, rollback, per-index net diffs,
   gas-before-access rules, canonical ordering, and system-operation indices.
3. Proof soundness: one side of every comparison is execution-derived and the
   other is supplied by the payload or proof claim.

## Adapter contract

The BlockSTF branch should add a small adapter with this logical surface:

```zig
const Produced = struct {
    state_root: Hash32,
    transactions_root: Hash32,
    receipts_root: Hash32,
    withdrawals_root: Hash32,
    requests: []const []const u8,
    requests_hash: Hash32,
    block_access_list: eth.bal.BlockAccessList,
    block_access_list_hash: Hash32,
};

fn materialize(recipe: Recipe) !BlockFixture;
fn produce(fixture: BlockFixture) !Produced;
fn compare(fixture: BlockFixture, claimed: Produced) !CompareStatus;
```

For each positive case:

1. Materialize named accounts, transactions, logs, withdrawals, and system
   contract storage into concrete fixture data.
2. Run `produce` and check every semantic assertion in `expect`.
3. Prefer freezing roots, request bytes, and the complete RLP BAL from EEST/EELS
   or another independent oracle. Do not bless the implementation under test as
   its own positive oracle.

For each `mutations` entry:

1. Start from the independently known-good claims.
2. Apply only the named mutation to either `input.*` or `claimed.*`.
3. Keep the opposite side frozen.
4. Run `compare` and require the symbolic `expect_status` category.

A mutation may update a claimed artifact and its dependent claimed commitment
together. In particular, the corpus changes fake request data together with its
`requests_hash`, and a fake BAL together with its `block_access_list_hash`. These
internally consistent claim bundles must still fail against execution-derived
requests and accesses.

Using `produce` from the implementation under test as the baseline is acceptable
for an early mismatch-routing smoke test, but it is not a conformance oracle.

## Fixture vocabulary

- `setup`: prestate and block conditions the materializer must create.
- `actions`: ordered block activity. A transaction index is its one-based block
  position, independent of whether EVM execution succeeds or reverts.
- `expect.assertions`: focused checks. Unmentioned state is not implicitly
  ignored; the final materialized golden fixture should still freeze the complete
  roots and BAL.
- `mutations`: one-sided negative checks. `input.*` changes execution input while
  claims stay frozen; `claimed.*` changes a claim while execution input stays
  frozen.
- `expect_status_any`: accepted categories when one input mutation necessarily
  changes multiple commitments and compare order determines the first mismatch.
- Named addresses and slots are selectors, not literal protocol values.

The adapter should map symbolic status categories to the branch's concrete enum.
Keep categories distinct where BlockSTF exposes distinct failures:

- `state_root_mismatch`
- `transactions_root_mismatch`
- `receipts_root_mismatch`
- `withdrawals_root_mismatch`
- `requests_hash_mismatch`
- `block_access_list_mismatch`
- `block_access_list_hash_mismatch`
- `invalid_deposit_event`
- `withdrawal_system_call_failure`
- `consolidation_system_call_failure`
- `block_access_list_too_large`

## Required invariants

- Phase order is `pre_system`, `transactions`, `withdrawals`, `post_system`,
  `derive_commitments`, `compare_or_commit`.
- BAL indices are `0`, then `1...n`, then `n + 1`.
- State writes from reverted frames are removed; accesses survive rollback.
- Each BAL storage write is a net change relative to state immediately before
  that block access index. A net-zero write is a read.
- EIP-7685 request objects are ordered by ascending type. Empty request data is
  omitted from `requests_hash`; a block with no request data uses `sha256("")`.
- EIP-6110 requests come from matching receipt logs in receipt/log order.
- EIP-7002 and EIP-7251 requests come from successful post-block system-call
  return data. Missing predeploy code or a failed call invalidates the block.
- Invalid blocks do not publish or commit partial state.
- A provided BAL is structurally validated before execution and must exactly
  equal the execution-derived BAL.
- Consistently mutating both a supplied artifact and its supplied hash never
  substitutes for comparing that artifact with execution.

## Sources

- EIP-6110: https://eips.ethereum.org/EIPS/eip-6110
- EIP-7002: https://eips.ethereum.org/EIPS/eip-7002
- EIP-7251: https://eips.ethereum.org/EIPS/eip-7251
- EIP-7685: https://eips.ethereum.org/EIPS/eip-7685
- EIP-7928: https://eips.ethereum.org/EIPS/eip-7928
