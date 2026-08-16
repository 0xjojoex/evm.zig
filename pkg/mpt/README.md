# mpt

Structural Ethereum Merkle Patricia Trie primitives for Zig 0.16 — canonical
topology, proofs, arbitrary-key updates, and fixed-key mutation.

`mpt` owns the *structure* of Ethereum's Merkle Patricia Trie, not the
meaning carried by it. It computes canonical roots, verifies proofs against a
sealed witness, and recomputes roots from sorted updates — operating purely on
nibble paths, hex-prefix encoding, and node RLP. Everything above that line —
accounts, storage, secure-key hashing, fork rules — lives in the caller.

- **Canonical.** Produces byte-for-byte Ethereum MPT roots, verified against the
  official `ethereum/tests/TrieTests` corpus.
- **Caller-owned memory policy.** A trie retains its caller-supplied allocator.
  Native tooling may grow; guests may use fixed or bump allocation.
- **Fixed Keccak, pluggable execution.** MPT commitments are always Keccak-256;
  a caller-supplied execution context lets native and zkVM backends implement
  that same rule. A stdlib default is included.
- **Honest absence.** A valid non-existence proof is a *result*; a missing or
  malformed witness node is an *error*. The two never blur.

## Why another MPT package?

Most trie libraries sit behind a database, cache, or persistent mutable state.
That is not the boundary a stateless executor receives. It starts with a trusted
root and a sealed bag of witness nodes, must authenticate exactly the available
topology, serve repeated reads without rehashing or decoding it, apply the final
mutations, and return a post-state root under caller-controlled memory.

This package therefore keeps three complementary representations instead of
turning one general trie into every phase:

- The arbitrary-key proof and sparse-update lane is the structural
  specification, conformance surface, and differential oracle.
- The immutable catalog authenticates and links witness-present topology once,
  while preserving missing hashed children as opaque references.
- The fixed-key mutation lane uses transient occurrences for 32-byte structural
  keys. A selected catalog child is materialized once, subsequent updates reuse
  it, untouched children remain authenticated references, and dirty nodes are
  encoded once at the end.

The last point is deliberate for Ethereum state and storage keys: Keccak-derived
keys disperse quickly, so sorted batches usually share only shallow prefixes. A
direct recursive batch fold adds partitioning machinery but finds little extra
topology to share; the occurrence overlay provides the useful memoization at a
smaller execution cost.

## Requirements

- Zig (matching the package's `build.zig.zon`).
- Depends only on the Zig standard library and the sibling `rlp` package for
  strict RLP encoding/decoding. No global state, database, or Ethereum types.

## Quick start

```zig
const mpt = @import("mpt");
const allocator = ...;
const trie = mpt.init(allocator);

// 1. Build a canonical root from key/value entries (std Keccak-256).
const entries = [_]mpt.Entry{
    .{ .key = "do",    .value = "verb" },
    .{ .key = "dog",   .value = "puppy" },
    .{ .key = "horse", .value = "stallion" },
};
const root_hash = try trie.root(&entries);

// 2. Verify a key against a trusted root, using a sealed witness index.
var indexed = try trie.indexNodes(encoded_nodes);
defer indexed.deinit();
const index = indexed.index();

switch (try trie.lookup(trusted_root, index, "dog")) {
    .present => |value| { /* authenticated value bytes, borrowed from the bag */ },
    .absent  => |reason| { /* valid non-existence: reason says why */ },
}

// 3. Recompute a post-root from sorted updates without materializing the whole trie.
const updates = [_]mpt.Update{
    .{ .key = "do",  .value = null },    // delete
    .{ .key = "dog", .value = "hound" }, // insert/replace
};
const post_root = try trie.updateSorted(trusted_root, index, &updates);
```

`mpt.init(allocator)` uses the stdlib Keccak context. For an accelerated
Keccak implementation, use `mpt.Trie(MyKeccak).init(allocator, context)`.

An optional typed-key facade projects domain keys into fixed 32-byte structural
keys while leaving values raw:

```zig
const Structural = mpt.Trie(MyKeccak);
const Accounts = Structural.Keyed(Address, AccountKeyContext);
const accounts = Accounts.init(structural_trie, account_key_context);

const result = try accounts.lookup(root_hash, index, address);
```

`KeyContext.trieKey(self, key)` owns only key projection. It does not change
node hashing, encode values, or add domain meaning to the structural trie.

## Core concepts

**Values.** An entry value must be non-empty. An empty byte string *is* absence
in Ethereum's MPT and is never stored, so higher layers map domain defaults
(e.g. a zero storage slot) to a delete rather than an empty value.

**Keys and ordering.** `rootSorted`, `updateSorted`, `updateFixedSorted`, and
`updateCatalogSorted` require strictly increasing, unique structural keys and
validate that before mutation. `root` copies the entry descriptors into
allocator-backed scratch and sorts them for you — it never copies key or value
bytes.

`Trie(...).Keyed(Key, KeyContext)` accepts typed keys whose `trieKey` projection
returns `mpt.FixedKey` (`[32]u8`). Typed lookup projects one key on the stack.
Typed root and update batches materialize projected keys and sort by those bytes
because domain-key ordering is not structural-key ordering. The typed
`updateCatalog` facade therefore sorts before calling the structural
`updateCatalogSorted` operation.

**Witness node index.** `indexNodes` borrows a slice of encoded nodes, hashes each
one exactly once, and builds an allocator-owned open-addressed position table at
no more than 50% load. It retains first-occurrence record order, collapses
identical duplicates, and rejects the same digest paired with conflicting bytes.
`IndexedNodes.deinit()` releases the records and table through its retained
allocator; the encoded node bytes remain borrowed. `IndexedNodes.index()` returns
an opaque borrowed capability; raw records cannot be assembled into an index
accepted by lookup or update. It serves any number of allocation-free lookups
and resolver-backed updates. `IndexedNodes.allocationBytes()` reports the bytes
retained by its owned records and table for guest budgeting. Extra irrelevant
nodes do not fail a proof.

**Authenticated catalog.** `catalogBuilder(index)` is an optional ingestion
layer over the sealed index. `authenticateRoot` decodes the witness-present
topology reachable from a trusted root into stable `u32` handles; `finish`
rejects resolved cycles and noncanonical extension topology, then seals an
immutable catalog whose lookup path performs no hashing, digest search,
allocation, or RLP decoding. Embedded children are always linked; a hashed child
absent from the witness stays opaque and produces `MissingNode` only when a
lookup or update selects it. Several state or storage roots may share one builder,
and content-addressed nodes retain one handle. `CatalogBuilder.leafValue` lets
ingestion code inspect authenticated leaf payloads without exposing catalog node
records. `Catalog.lookupBound` returns `BoundLookup`, adding the stable terminal
`CatalogNodeId` needed by typed caches to the ordinary lookup result.

**Fixed-key mutation.** `updateFixedSorted` and `updateCatalogSorted` share one
MPT mutation algebra for exactly 32-byte keys. The former resolves authenticated
nodes lazily from a sealed witness index and uses the trie's allocator; the
latter carries stable catalog handles and takes a resettable `Region` from the
caller. Both create mutable occurrences only along selected paths, retain
untouched children as authenticated references, and encode dirty ancestors
bottom-up. An occurrence is the memoized write overlay, not another authenticated
source of truth. Fixed width also makes branch terminal values and prefix keys
structurally invalid; arbitrary-width keys remain on `updateSorted` in the sparse
engine.

**Fixed-key binding.** `bindSorted` and `bindAssumeSorted` batch authenticated
lookups through a catalog without allocation or RLP decoding. Their
`BindWorkspace` is a fixed 65-frame traversal stack. `FixedLookup` uses the
smaller fixed-key absence algebra, which deliberately omits the impossible
`empty_branch_value` result.

**Lookup outcomes.** `lookup` returns a `Lookup` union:

- `.present` — the authenticated value bytes (borrowed from the bag; they cannot
  outlive it).
- `.absent` — a valid non-existence proof, tagged with an `Absence` reason:
  `empty_trie`, `divergent_path`, `missing_branch_child`, or
  `empty_branch_value`.

An omitted-but-required hashed node instead returns `error.MissingNode` — an
incomplete witness, never a proof of absence.

Repeated arbitrary-key reads may pass a `LookupCache` to `lookupCached`. The
cache owns only lookup memoization; authenticated value bytes remain borrowed
from the indexed witness just as they are for `lookup`.

**Sparse update.** `updateSorted` materializes only the nodes on changed paths;
unvisited hashed siblings stay as blind 32-byte references. A non-null value
inserts or replaces; a null value deletes; deleting an absent key is a no-op.
Deletion performs canonical branch compression. The input bag and root are
immutable, and a failed call leaves no partial state.

## Resource model

`init` takes an allocator retained by the trie; `root`, `rootSorted`,
`indexNodes`, `updateSorted`, and `updateFixedSorted` use it.
`updateCatalogSorted` takes an explicit resettable `Region`; the typed
`updateCatalog` facade also allocates its projected update descriptors there. A
normal heap may grow, while `FixedBufferAllocator` or a guest bump allocator
imposes a hard memory ceiling. The allocator must outlive the trie and every
`IndexedNodes` it creates. `lookup` remains allocation-free after indexing and
is also available as the top-level `mpt.lookup`.

The primary API has no caller-supplied limits. Sparse update grows touched
topology incrementally through the retained allocator instead of reserving a
speculative worst-case workspace. A normal allocator grows; a fixed or bump
allocator enforces the caller's chosen envelope. Arithmetic or representability
overflow returns `error.ResourceLimitExceeded`; allocator exhaustion returns
`error.OutOfMemory`.

Untrusted input admission belongs at the surrounding wire or application
boundary. The stateless guest, for example, validates SSZ list and byte-list
maxima before invoking MPT; its fixed allocator independently caps memory.

`RootWorkspace`, `rootWorkspaceSize(entries, include_sort)`,
`rootWorkspaceSizeForLimits`, and the root `*WithWorkspace` entry points remain
advanced APIs for exact full-root scratch reuse. The limits form computes a
bound when descriptors are not yet materialized. Indexing and sparse update
deliberately have no caller-storage sizing API: bounded callers use a fixed
allocator rather than exposing mutable index records or relying on an
inaccurate sparse preflight size.

Peak memory is bounded: indexed lookup is `O(witness_nodes)` and then allocates
nothing per lookup; a full root is `O(entries + key topology + max_node_rlp_bytes)`;
a sparse update is `O(touched_nodes + max_node_rlp_bytes)`. The implementation
never retains every encoded internal node, so a one-shot zkVM Keccak provider
stays on the fast path without incremental hashing.

The optional catalog is `O(reachable_hashed_nodes + embedded_occurrences)` and is
deliberately not constructed by ordinary proof/update users: one compact
descriptor per linked node plus one child row per branch, on top of the witness
index records ingest already retains. Its descriptors encode node-relative spans
as `u16`, so catalog ingestion rejects an encoded node larger than 65,535 bytes
with `ResourceLimitExceeded` — a catalog-only representation bound that leaves
the generic proof and sparse-update APIs unchanged.

`catalogBuilderWithLimits` additionally bounds indexed node count, linked nodes
(including embedded occurrences), and branch rows; exceeding a bound returns
`ResourceLimitExceeded`, and applications can retain the ordinary proof reader
as a correctness-preserving fallback. All of this happens after the witness index
exists, so surrounding wire admission must separately bound raw witness
count/bytes. The package chooses no policy numbers for either layer.

## Keccak execution context

Any type with `pub fn keccak256(self, input: []const u8) mpt.Root` is a valid
execution context; `Trie(KeccakContext)` validates that shape at comptime and
stores one context value beside its allocator. The algorithm is fixed: contexts
cannot redefine protocol commitments or the package-owned empty-root constant.
Wrapping a context is the intended way to route a zkVM accelerator or count
node hashes for tests and benchmarks.

## Scope

`mpt` deliberately stops at structural keys and non-empty byte values. The
generic lane accepts raw byte keys; the fixed lane accepts `FixedKey`; and the
typed facade only projects caller-owned domain keys into that fixed structural
form. The package does **not** own persistent storage, pruning, snapshots,
database update sets, proof generation, or any Ethereum type — accounts,
storage schemas, transactions, receipts, withdrawals, secure-key hashing, and
fork rules all live above it.

## Conformance

The package gate pins and runs all five official `ethereum/tests/TrieTests`
construction files. Secure-trie fixtures hash their keys in a fixture adapter;
the package itself carries no `secure` mode. On top of the corpus, tests cover
canonical anchors, insertion-order independence, typed absence, missing and
conflicting nodes, one-occupant branches, exact 31/32/33-byte reference
behavior, malformed compact paths and RLP, sparse insert/replace/delete with
hashed-sibling collapse, allocator exhaustion, long retained witness paths, and
misaligned/undersized full-root workspace.

The fuzz gate generates shared-prefix, divergent, and prefix-chain tries. It
requires sorted construction, unsorted construction, exact-size workspace
construction, and sparse insertion from the empty root to produce the same
root. It also round-trips generated leaf proofs, checks witness-backed replace
and delete, differentially checks fixed-key index and catalog mutation against
full construction, and feeds arbitrary encoded nodes and keys through proof
lookup.

```sh
zig build test
zig build fuzz                 # run the seed corpus
zig build fuzz --fuzz=10000    # run the builtin fuzzer
```

## License

Licensed under either the [Apache License, Version 2.0](LICENSE-APACHE) or the
[MIT license](LICENSE-MIT), at your option.
