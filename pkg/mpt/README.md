# mpt

Structural Ethereum Merkle Patricia Trie primitives for Zig 0.16 — canonical
topology, proofs, and sparse updates over raw byte keys and values.

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

// 3. Recompute a post-root from sorted updates without materializing the trie.
const updates = [_]mpt.Update{
    .{ .key = "dog", .value = "hound" }, // insert/replace
    .{ .key = "do",  .value = null },    // delete
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

**Keys and ordering.** `rootSorted` and `updateSorted` require strictly
increasing, unique keys and validate that before doing any work. `root` copies
the entry descriptors into allocator-backed scratch and sorts them for you — it never
copies key or value bytes.

`Trie(...).Keyed(Key, KeyContext)` accepts typed keys whose `trieKey` projection
returns `[32]u8`. Typed lookup projects one key on the stack. Typed root and
update batches materialize projected keys and sort by those bytes because
domain-key ordering is not structural-key ordering.

**Witness node index.** `indexNodes` borrows a slice of encoded nodes, hashes each
one exactly once into allocator-owned internal record storage, sorts by hash for
deterministic binary lookup, collapses identical duplicates, and rejects the
same digest paired with conflicting bytes. `IndexedNodes.deinit()` releases the
records through its retained allocator; the encoded node bytes remain borrowed.
`IndexedNodes.index()` returns an opaque borrowed capability; raw records cannot
be assembled into an index accepted by lookup or update. It serves any number
of allocation-free lookups and updates. Extra irrelevant nodes do not fail a proof.

**Lookup outcomes.** `lookup` returns a `Lookup` union:

- `.present` — the authenticated value bytes (borrowed from the bag; they cannot
  outlive it).
- `.absent` — a valid non-existence proof, tagged with an `Absence` reason:
  `empty_trie`, `divergent_path`, `missing_branch_child`, or
  `empty_branch_value`.

An omitted-but-required hashed node instead returns `error.MissingNode` — an
incomplete witness, never a proof of absence.

**Sparse update.** `updateSorted` materializes only the nodes on changed paths;
unvisited hashed siblings stay as blind 32-byte references. A non-null value
inserts or replaces; a null value deletes; deleting an absent key is a no-op.
Deletion performs canonical branch compression. The input bag and root are
immutable, and a failed call leaves no partial state.

## Resource model

`init` takes an allocator retained by the trie; `root`, `rootSorted`,
`indexNodes`, and `updateSorted` use it. A normal heap may grow, while
`FixedBufferAllocator` or a guest bump allocator imposes a hard memory ceiling.
The allocator must outlive the trie and every `IndexedNodes` it creates.
`lookup` remains allocation-free after indexing and is also available as the
top-level `mpt.lookup`.

The primary API has no caller-supplied limits. Sparse update grows touched
topology incrementally through the retained allocator instead of reserving a
speculative worst-case workspace. A normal allocator grows; a fixed or bump
allocator enforces the caller's chosen envelope. Arithmetic or representability
overflow returns `error.ResourceLimitExceeded`; allocator exhaustion returns
`error.OutOfMemory`.

Untrusted input admission belongs at the surrounding wire or application
boundary. The stateless guest, for example, validates SSZ list and byte-list
maxima before invoking MPT; its fixed allocator independently caps memory.

`Workspace`, `rootWorkspaceSize(entries, include_sort)`, and the root
`*WithWorkspace` entry points remain advanced APIs for exact full-root scratch
reuse. Indexing and sparse update deliberately have no caller-storage sizing
API: bounded callers use a fixed allocator rather than exposing mutable index
records or relying on an inaccurate sparse preflight size.

Peak memory is bounded: indexed lookup is `O(witness_nodes)` and then allocates
nothing per lookup; a full root is `O(entries + key topology + max_node_rlp_bytes)`;
a sparse update is `O(touched_nodes + max_node_rlp_bytes)`. The implementation
never retains every encoded internal node, so a one-shot zkVM Keccak provider
stays on the fast path without incremental hashing.

## Keccak execution context

Any type with `pub fn keccak256(self, input: []const u8) mpt.Root` is a valid
execution context; `Trie(KeccakContext)` validates that shape at comptime and
stores one context value beside its allocator. The algorithm is fixed: contexts
cannot redefine protocol commitments or the package-owned empty-root constant.
Wrapping a context is the intended way to route a zkVM accelerator or count
node hashes for tests and benchmarks.

## Scope

`mpt` deliberately stops at raw byte keys and non-empty byte values. It does
**not** own persistent storage, pruning, snapshots, database update sets, proof
generation, or any Ethereum type — accounts, storage schemas, transactions,
receipts, withdrawals, secure-key hashing, and fork rules all live above it.

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
and delete, and feeds arbitrary encoded nodes and keys through proof lookup.

```sh
zig build test
zig build fuzz                 # run the seed corpus
zig build fuzz --fuzz=10000    # run the builtin fuzzer
```
