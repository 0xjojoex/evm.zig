# Ethereum Block STF Review Guide

This guide is for reading the current `eth.BlockSTF` implementation without
needing all Ethereum block-transition details in your head first.

Think of the VM as a checkout counter and BlockSTF as the store manager closing
the day. The counter can process one customer after another, keep a running
total, and roll back a customer that cannot fit the rules. The manager owns the
opening tasks, the closing tasks, the daily ledger, and the final comparison
against the official receipt.

```text
stateless/wire/v1.zig
  decodes the versioned guest input and normalizes external fields
        |
        v
stateless/validate.zig
  prepares witness-backed Ethereum execution input
        |
        v
eth/block_stf.zig
  Ethereum block lifecycle and consensus checks
        |
        v
Vm.BlockSession
  ordered transaction fold over one VM overlay
        |
        v
Executor + Overlay + state.Backend
  message execution over a witness-backed or client-provided state source
```

## Core Boundary

`Vm.BlockSession` is intentionally thin. It sequences transactions under one
environment, accumulates gas, builds borrowed receipt views, and rolls back a
transaction when cumulative block gas would overflow the block.

`eth.BlockSTF` is the Ethereum block state-transition function layer above it.
It owns the fork-specific block lifecycle: block-start system contracts,
transaction folding, withdrawal credits, block-end request derivation, root
assembly, and mismatch taxonomy.

The dependency direction should stay one-way:

```text
BlockSTF drives BlockSession.
BlockSession does not learn Ethereum header/body policy.
```

When reviewing changes, this is the first smell test. If a patch makes
`BlockSession` understand withdrawals, requests, payload roots, header fields,
or fork-specific block hooks, the boundary is drifting downward.

## Main Files

- `src/eth/block_stf.zig`: the block transition orchestrator.
- `src/eth/header.zig`: canonical fork-aware execution-header RLP and hash.
- `src/eth/transaction_prepare.zig`: revision-aware Ethereum transaction
  preparation and exact check/read ordering.
- `src/eth/transaction_validation.zig`: Ethereum transaction validity rules.
- `src/vm.zig`: `Vm.BlockSession`, transaction execution, gas fold, rollback.
- `src/stateless/wire/v1.zig`: immutable schema-v1 SSZ codec and normalizer.
- `src/stateless/validate.zig`: normalized stateless input adapter into
  `BlockInput`.
- `src/executor/system_contracts.zig`: block-start and block-end system calls.
- `src/state/Backend.zig`: block-lifetime reader/root/commit capability.
- `src/eth/eip/*.zig`: request and system-contract helpers.
- `src/mpt.zig`: trie roots for state, transactions, receipts, withdrawals.

## Input Shape

`BlockInput` is the handoff from caller to BlockSTF:

- `revision`, `config`, `env`: which fork and execution environment to run.
- `block_header`: fields needed for block hooks and header reconstruction.
- `parent_header`: canonical parent hash and scalar fields used to validate
  child number, timestamp, gas limit, base fee, and blob-gas derivation.
- `state_backend`: state reader, post-changeset root derivation, and optional
  commit capability. Witnesses are one backend implementation.
- `transactions`: decoded VM transactions plus the original encoded bytes.
- `withdrawals`: execution-layer withdrawal list.
- `parent_blob_gas`: parent context for blob gas.
- `block_access_list`: optional claimed RLP BAL bytes.
- `root_checks`: independently sourced root claims.
- `header_claims`: scalar/header commitments such as gas, bloom, requests, and
  BAL hash.
- `header_hash_claim`: payload block hash plus non-derived header fields needed
  to reconstruct the canonical execution header.
- `trace_sink`: optional tracing hook scoped to payload transactions.

The stateless wire path first converts `NewPayloadRequest`, chain config, and
witness material into `stateless.Input`. The validator constructs a witness
`state.Backend`, then builds `BlockInput` from normalized runtime facts.

## Witness Model

The stateless path starts from claimed pre-state material:

- `pre_state_root`: the parent state root.
- `witness_nodes`: trie nodes needed to read and later update touched state.
- `codes`: bytecode blobs keyed by code hash.
- `witness.headers`: recent headers used for block-hash lookups and parent
  context.

The stateless adapter wraps this material in `state.Backend.fromWitness`.
BlockSTF itself only consumes the backend capability, so regular clients can
instead provide an external reader, root provider, and committer. Missing or
malformed witness data becomes `invalid_witness` in the witness-backed lane.

The state reader exposes three independent facts: account metadata
(`nonce`, `balance`, `code_hash`) by address, code bytes by `code_hash`, and
storage by address/slot. `Overlay` caches code content-addressably and journals
only account hashes. Missing or malformed witness code is classified by
`WitnessStateReader`; `Overlay` propagates that error without inventing witness
semantics.

## Execution Flow

`apply` runs the block in this order:

```text
1. Validate fork-gated body fields, parent-derived header rules, and block-start
   context against the active revision and execution environment.
2. Ask the supplied state backend for its reader.
3. Initialize Vm using the Ethereum protocol and backend reader.
4. Pre-validate claimed BAL shape when one is supplied.
5. Install internal BAL recorder when Amsterdam/BAL claims require it.
6. Run block-start system contracts when a block header is provided.
7. Install caller trace sink for payload transactions only.
8. Begin a Vm.BlockSession.
9. For each transaction:
   - account for blob gas and reject before execution if the active block cap
     would be exceeded
   - prepare and execute through BlockSession.transact
   - reject invalid txs or block-gas overflow with a status
   - build receipt view
   - merge logs bloom
   - derive EIP-6110 deposit request data from receipt logs on Prague+
   - encode receipt for receipts_root
10. Compute excess blob gas when parent blob context is present.
11. Apply withdrawal balance credits directly through the VM overlay.
12. Keep only internal BAL tracing active for withdrawals and block-end calls.
13. Run block-end system contracts and derive EIP-7002/EIP-7251 requests.
14. Hash derived requests and derive BAL hash.
15. Build changeset from the VM overlay.
16. Recompute state, transaction, receipt, and withdrawal roots.
17. Reconstruct the fork-aware execution header and canonical RLP hash when a
    block-hash claim is supplied.
18. Compare execution-derived outputs and the reconstructed hash against
    claims, then commit state only if every check remains valid.
```

The important sequencing rule is that state-affecting block operations happen
before `evm.changeset()`, because the state root is derived from that changeset.

Parent validation happens before VM construction. Post-Merge non-genesis
blocks must link to the supplied parent hash and increment its number, use a
strictly later timestamp, stay within the parent gas-limit adjustment bounds,
and carry the EIP-1559 base fee derived from the parent's gas usage.

## Transaction Results

There are two different failure shapes:

- Rejected before execution: no receipt should be produced. BlockSTF returns
  `transaction_rejected`.
- Executed but failed inside EVM: receipt is produced with status `0` for
  `revert`, `invalid`, or `out_of_gas`.

`BlockSession.transact` returns either `.executed` or `.rejected`. BlockSTF only
builds receipts from `.executed`.

Block-resource allowance is checked during protocol preparation against the
session's pre-transaction progress. A transaction whose declared gas cannot fit
is rejected with `gas_allowance_exceeded` before execution. `BlockSession` still
keeps its post-execution fold-and-rollback check as a defensive boundary; an
overflow there is reported as `block_gas_exceeded`.

## Transaction Preparation

`BlockSession` does not know Ethereum transaction validity rules. It calls the
resolved `Protocol.Transaction.prepare` hook exactly once with:

- the active revision and transaction value
- block environment facts
- cumulative receipt and dimensional block-gas progress
- a read-only state capability exposing account metadata and hash-addressed code

The Ethereum definition binds that hook to `eth/transaction_prepare.zig`. Its
Amsterdam path follows the composed fork order:

```text
envelope/type and intrinsic checks
transaction nonce maximum, initcode, block-resource, blob-cap checks
        |
        v
accountSummary(sender)
        |
        v
fee, blob/set-code shape, account nonce, funds checks
        |
        v
code(sender, code_hash), when sender-code policy is active
        |
        v
Prepared transaction
```

This order is consensus behavior, not a performance heuristic. A missing sender
proof cannot hide an intrinsic-gas or maximum-transaction-nonce rejection, but
it must still surface before a fee rejection that the integrated fork checks
after loading the sender. Likewise, sender code is not requested until nonce and
funds checks pass.

Preparation can populate read caches but cannot mutate balances, nonces, code,
storage, logs, refunds, or transaction warmth. It does not read recipient state;
recipient existence and delegation remain execution-time facts. The result
boundary stays explicit:

- `.rejected`: protocol-invalid transaction
- state/backend error such as `InvalidWitness`: validity could not be decided
- `.executable`: fully prepared transaction, after which `BlockSession` opens
  its rollback snapshot and executes

## Root Provenance

A root comparison is only meaningful if exactly one side came from execution and
the other side came from a real payload/header claim.

```text
good:
  execution-derived receipts_root  vs payload header receipts_root claim

bad:
  payload transactions list root    vs root recomputed from same transactions
```

The current code models claims with provenance-typed roots:

- `PayloadHeaderRoot`: a claim carried directly by the payload/header surface.
- `ReconstructedHeaderRoot`: a claim from an independently reconstructed header.
- `execution_derived`: the output produced by BlockSTF.

The consensus comparison matrix in `src/eth/block_stf.zig` allows:

```text
state        execution-derived vs payload header claim
transactions execution-derived vs reconstructed header claim
receipts     execution-derived vs payload header claim
withdrawals  execution-derived vs reconstructed header claim
```

Body-only recomputes are not accepted as claim inputs. Transaction and
withdrawal roots are compared only when an independently reconstructed header
supplies the claimed side.

## Header Claims

`HeaderClaims` covers non-root values:

- `gas_used`
- `block_gas_used`
- `block_state_gas_used`
- `logs_bloom`
- `blob_gas_used`
- `excess_blob_gas`
- `requests_hash`
- `block_access_list_hash`

There are multiple gas surfaces. `gas_used` is the cumulative receipt gas. The
block/header gas surface can be dimensional, especially around Amsterdam-style
block gas accounting, so the ABI may map a payload field to `block_gas_used`
instead of legacy `gas_used` depending on revision.

These are compared after root checks, while `Result.status` is still `.valid`.
The first mismatch wins. This keeps the result status easy to classify, but it
also means a test for a later mismatch must satisfy all earlier checks.

Blob gas has an independent per-block cap. BlockSTF derives the active schedule
from the revision or explicit chain override and rejects the transaction that
would make cumulative blob gas exceed `schedule.max * schedule.gas_per_blob`.
The EEST adapters preserve the fork-specific `config.blobSchedule` override in
both this cap and the blob base-fee calculation.

`ExecutionHeader` is the collective header commitment. Its fork-gated field
surface runs from the legacy fields through London base fee, Shanghai
withdrawals, Cancun blob/beacon fields, Prague requests, and Amsterdam BAL hash
plus slot number. BlockSTF fills execution outputs such as state, transaction,
receipt, withdrawal, request, and BAL roots from `Result`; `HeaderHashClaim`
provides the payload block hash and non-derived fields such as parent hash and
extra data. A mismatch returns `block_hash_mismatch`.

The regular fixture adapter uses a valid reconstructed hash for parent
continuity and historical `BLOCKHASH`. The witness adapter checks its immediate
fixture parent and supplies that hash to `BLOCKHASH` as well. Amsterdam fixture
gas remains the one exception: regular EEST reconstruction uses the payload gas
scalar and reports `unchecked.amsterdam_gas_used` until block gas accounting is
aligned.

## Requests

Execution requests are a Prague+ block output. They are not plain payload input.

BlockSTF derives them from two execution sources:

- EIP-6110 deposits: parse deposit events from transaction receipt logs.
- EIP-7002/EIP-7251: run block-end system contracts and copy their outputs into
  typed request bytes.

The stateless ABI currently hashes payload `execution_requests` as the claimed
`requests_hash`, while BlockSTF hashes the execution-derived request list as the
produced value. This makes mutated request payloads reject for the right reason:
claim changes, execution result does not.

## Withdrawals

Withdrawals have two independent effects:

- The withdrawal list has a withdrawals root.
- Each withdrawal credits the recipient balance before the final state root is
  computed.

The credit path belongs in BlockSTF, not BlockSession, because it is block
lifecycle policy rather than transaction sequencing. The VM exposes
`creditBalance` as a small state primitive so BlockSTF can write through the
overlay without teaching BlockSession about withdrawals.

## Block Access List

Amsterdam adds an execution-derived EIP-7928 block access list. BlockSTF records
state/account trace events into `eth.bal_recorder`, derives canonical BAL bytes,
and hashes them with `eth.bal.hash` semantics.

There are two BAL checks:

- `block_access_list_mismatch`: supplied BAL bytes do not match execution.
- `block_access_list_hash_mismatch`: supplied hash does not match the derived
  BAL hash.

Malformed supplied BAL is rejected before execution. A supplied or observed BAL
that exceeds the gas-limit item bound returns `block_access_list_too_large`.
Zero-amount withdrawals still count as account accesses for BAL.

## Trace Scope

Block-start and block-end system contracts are part of block execution, but the
public caller trace sink is scoped to payload transactions only.

```text
block-start hooks      internal BAL trace only
payload transactions   caller trace plus internal BAL trace
withdrawals/hooks      internal BAL trace only
```

This keeps payload tracing stable while letting BlockSTF derive full-block BAL.
A future public trace design can expose more phases, but review should not
assume all system calls are included in the caller's payload transaction trace.

## Public Stateless Surface

`src/stateless.zig` re-exports BlockSTF types for existing guest callers, but it
does not own block semantics. The real implementation lives in
`src/eth/block_stf.zig`.

The wire dispatcher has both boolean and detailed result entry points:

- `validateStatelessBytes`: returns guest-style validity.
- `validateStatelessResultBytes*`: returns the detailed `block_stf.Result`
  status and derived outputs.

When reviewing a failure, prefer the detailed result path. The boolean API is
useful for guest pass/fail, but it hides the mismatch taxonomy.

## Common Gotchas

The biggest gotcha is mistaking a recompute for a claim. If both operands are
derived from the same payload body list, the check is a self-comparison and does
not prove consensus validity.

Another gotcha is mismatch reachability. A status such as
`requests_hash_mismatch` or `withdrawals_root_mismatch` is useful only if a test
can mutate one side while the other side remains execution-derived.

Allocation ownership is also easy to lose in this path. Decoding stateless input
often creates owned transaction/request/list data, while many VM receipt/log
views are borrowed and valid only near the execution point where they are read.

Finally, fork gates matter. BlockSTF rejects fork-inactive body fields before
state access, while each adapter validates the actual wire or fixture shape it
normalizes.

System-contract absence is not always a failure. A missing block-end request
contract can be a no-op unless the call requires code; code-present failure is
reported as `system_contract_failed`.

## Review Checklist

Use this when reading a patch:

- Does BlockSTF still drive BlockSession rather than pushing block policy into
  `Vm.BlockSession`?
- Is every consensus comparison execution-derived on exactly one side?
- Are root claims sourced from a payload or independently reconstructed header?
- Are withdrawals credited before `evm.changeset()`?
- Are requests derived from receipts/system calls rather than trusted from the
  payload?
- Is BAL derived from internal execution trace instead of trusted from payload
  bytes?
- Does BAL use index `0` for pre-system work, `1..n` for transactions, and
  `n + 1` for withdrawals/block-end work?
- Are fork-specific body fields gated directly by the active revision?
- Does a claimed block hash come from canonical `ExecutionHeader` hashing, and
  is only a validated reconstructed hash promoted into parent history?
- Are owned allocations freed on every error path?
- Do tests mutate the claimed side and prove the corresponding mismatch status
  is reachable?

## Semantic Fixtures

`src/test/fixtures/block_stf/cases.json` is the adapter contract for future
BlockSTF conformance. It is still semantic, not a full materialized oracle. The
current `src/test/block_stf_cases.zig` layer parses all cases, locks expected
status categories against `block_stf.Status`, and runs smoke checks for the
cases BlockSTF can honestly materialize without a richer recipe builder.

## Current Open Edges

Transaction and withdrawal local body recomputes are intentionally not exposed
as standalone consensus root comparisons. Their execution-derived roots are
nevertheless bound into the canonical execution-header hash. A future decoded
header input could make the individual mismatch statuses independently
reachable without weakening provenance.

Amsterdam block gas accounting still differs from fixture `gasUsed`; the
regular adapter labels that scalar unchecked. The broader witness fixture lane
also retains known BAL, gas, typed-transaction, and checkpoint-trace gaps beyond
the supported positive slice.

Allocator cleanup still deserves a focused pass in the public stateless decode
and validation paths.

`ValidationOptions` is currently present in the wire validation path but unused.
