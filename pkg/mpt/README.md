# mpt

Structural Ethereum Merkle Patricia Trie primitives for Zig 0.16 — canonical
topology, proofs, arbitrary-key updates, and fixed-key mutation.

`mpt` owns the *structure* of Ethereum's MPT, not the meaning carried by it:
nibble paths, hex-prefix encoding, node RLP, canonical roots, proofs against a
sealed witness, and post-roots from sorted updates. Everything above that
line — accounts, storage, secure-key hashing, fork rules — lives in the caller.

- **Canonical.** Byte-for-byte Ethereum MPT roots, verified against the
  official `ethereum/tests/TrieTests` corpus.
- **Caller-owned memory policy.** A trie retains its caller-supplied allocator;
  native tooling may grow, guests may pass fixed or bump allocation.
- **Fixed Keccak, pluggable execution.** Commitments are always Keccak-256; a
  caller-supplied execution context routes them to native or zkVM backends. A
  stdlib default is included.
- **Honest absence.** A valid non-existence proof is a *result*; a missing or
  malformed witness node is an *error*. The two never blur.

## Why another MPT package?

Most trie libraries sit behind a database, cache, or persistent mutable state.
A stateless executor receives a different boundary: a trusted root and a sealed
bag of witness nodes. It must authenticate exactly the available topology,
serve repeated reads without rehashing or re-decoding it, apply the final
mutations, and return a post-state root under caller-controlled memory.

The package therefore keeps three complementary representations instead of
bending one general trie to every phase:

- The arbitrary-key proof and sparse-update lane is the structural
  specification, conformance surface, and differential oracle.
- The immutable catalog authenticates and links witness-present topology once,
  keeping missing hashed children as opaque references.
- The fixed-key mutation lane overlays transient occurrences on 32-byte
  structural keys: a selected child materializes once, later updates reuse it,
  untouched children stay authenticated references, and dirty nodes encode
  once at the end.

The overlay fits hashed keys well: Keccak-derived keys disperse quickly, so an
update batch shares little deep topology. Memoizing each materialized path
across the batch captures the sharing that does exist, without dedicated batch
machinery.

## Install

`mpt` is one of the modules exported by
[`evmz`](https://github.com/0xjojoex/evm.zig), which is fetched as a single
package:

```sh
zig fetch --save git+https://github.com/0xjojoex/evm.zig
```

```zig
// build.zig
const evmz = b.dependency("evmz", .{
    .target = target,
    .optimize = optimize,
    .core = false, // skip the EVM core and its C dependencies
});
exe.root_module.addImport("mpt", evmz.module("mpt"));
```

Depends only on the Zig standard library and the sibling `rlp` module for
strict RLP encoding/decoding — wired for you by the same fetch. No global
state, database, or Ethereum types.

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
    .present => |value| { /* authenticated value bytes */ },
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

`Trie(...).Keyed(Key, KeyContext)` accepts typed keys whose `trieKey`
projection returns `mpt.FixedKey` (`[32]u8`). Typed lookup projects one key on
the stack; typed root and update batches materialize projected keys and sort by
those bytes before the structural call, because domain-key ordering is not
structural-key ordering.

**Witness node index.** `indexNodes` borrows a slice of encoded nodes, hashes
each exactly once, and builds an allocator-owned open-addressed position table
at no more than 50% load — first-occurrence record order, identical duplicates
collapsed, one digest with conflicting bytes rejected. `IndexedNodes.index()`
returns an opaque borrowed capability serving any number of allocation-free
lookups and resolver-backed updates; raw records cannot be assembled into an
accepted index. `deinit()` releases records and table through the retained
allocator while the encoded node bytes stay borrowed, and `allocationBytes()`
reports the retained bytes for guest budgeting. Extra irrelevant nodes do not
fail a proof.

**Authenticated catalog.** `catalogBuilder(index)` is an optional ingestion
layer over the sealed index. `authenticateRoot` decodes the witness-present
topology reachable from a trusted root into stable `u32` handles; `finish`
rejects resolved cycles and noncanonical extension topology, then seals an
immutable catalog whose lookup path performs no hashing, digest search,
allocation, or RLP decoding. Embedded children are always linked; a hashed
child absent from the witness stays opaque and produces `MissingNode` only when
a lookup or update selects it. Several state or storage roots may share one
builder, and content-addressed nodes retain one handle.
`CatalogBuilder.leafValue` lets ingestion code inspect authenticated leaf
payloads without exposing catalog records. `Catalog.lookupBound` returns
`BoundLookup`, adding the stable terminal `CatalogNodeId` needed by typed
caches.

**Fixed-key mutation.** `updateFixedSorted` and `updateCatalogSorted` share one
MPT mutation algebra for exactly 32-byte keys. The former resolves
authenticated nodes lazily from a sealed witness index; the latter carries
stable catalog handles. Both take a resettable `Region` from the caller, create
mutable occurrences only along selected paths, retain untouched children as
authenticated references, and encode dirty ancestors bottom-up — a memoized
write overlay, not another authenticated source of truth. Fixed width makes
branch terminal values and prefix keys structurally invalid; arbitrary-width
keys remain on `updateSorted` in the sparse engine.

**Fixed-key binding.** `bindSorted` and `bindAssumeSorted` batch authenticated
lookups through a catalog without allocation or RLP decoding, sharing prefixes
across a fixed 65-frame `BindWorkspace`. `FixedLookup` uses the smaller
fixed-key absence algebra, which omits the impossible `empty_branch_value`
result.

**Lookup outcomes.** `lookup` (also exported as the top-level `mpt.lookup`)
returns a `Lookup` union:

- `.present` — the authenticated value bytes, borrowed from the bag; they
  cannot outlive it.
- `.absent` — a valid non-existence proof, tagged with an `Absence` reason:
  `empty_trie`, `divergent_path`, `missing_branch_child`, or
  `empty_branch_value`.

An omitted-but-required hashed node instead returns `error.MissingNode` — an
incomplete witness, never a proof of absence. Repeated arbitrary-key reads may
pass a `LookupCache` to `lookupCached`; the cache owns only memoization.

**Sparse update.** `updateSorted` materializes only the nodes on changed paths;
unvisited hashed siblings stay as blind 32-byte references. A non-null value
inserts or replaces; a null value deletes; deleting an absent key is a no-op.
Deletion performs canonical branch compression. The input bag and root are
immutable, and a failed call leaves no partial state.

## Resource model

`init` takes an allocator retained by the trie; `root`, `rootSorted`,
`indexNodes`, and `updateSorted` use it, and it must outlive the trie and every
`IndexedNodes` it creates. Both fixed-key mutation paths take an explicit
resettable `Region`; the typed `update` and `updateCatalog` facades also
allocate their projected update descriptors there.

The primary API has no caller-supplied limits: touched topology grows
incrementally through the allocator rather than reserving a speculative
worst case, so a normal heap grows while a fixed or bump allocator enforces
the caller's chosen envelope. Arithmetic or representability overflow returns
`error.ResourceLimitExceeded`; allocator exhaustion returns
`error.OutOfMemory`. Untrusted input admission belongs at the surrounding wire
or application boundary — the stateless guest, for example, validates SSZ list
and byte-list maxima before invoking MPT, and its fixed allocator independently
caps memory.

`RootWorkspace`, `rootWorkspaceSize(entries, include_sort)`,
`rootWorkspaceSizeForLimits`, and the root `*WithWorkspace` entry points remain
advanced APIs for exact full-root scratch reuse; the limits form computes a
bound before descriptors are materialized. Indexing and sparse update
deliberately have no caller-storage sizing API: bounded callers use a fixed
allocator rather than exposing mutable index records or relying on an
inaccurate sparse preflight size.

Peak memory is bounded: indexed lookup is `O(witness_nodes)` and then allocates
nothing per lookup; a full root is `O(entries + key topology + max_node_rlp_bytes)`;
a sparse update is `O(touched_nodes + max_node_rlp_bytes)`. The implementation
never retains every encoded internal node, so a one-shot zkVM Keccak provider
stays on the fast path without incremental hashing.

The optional catalog is `O(reachable_hashed_nodes + embedded_occurrences)` —
one compact descriptor per linked node plus one child row per branch, on top of
the witness index records ingest already retains — and is deliberately not
constructed by ordinary proof/update users. Its descriptors encode
node-relative spans as `u16`, so catalog ingestion rejects an encoded node
larger than 65,535 bytes with `ResourceLimitExceeded` — a catalog-only bound
that leaves the generic proof and sparse-update APIs unchanged.
`catalogBuilderWithLimits` additionally bounds indexed node count, linked nodes
(including embedded occurrences), and branch rows; exceeding a bound returns
`ResourceLimitExceeded`, and applications can retain the ordinary proof reader
as a correctness-preserving fallback. All of this happens after the witness
index exists, so wire admission must separately bound raw witness count and
bytes. The package chooses no policy numbers for either layer.

## Keccak execution context

Any type with `pub fn keccak256(self, input: []const u8) mpt.Root` is a valid
execution context; `Trie(KeccakContext)` validates that shape at comptime and
stores one context value beside its allocator. The algorithm is fixed: contexts
cannot redefine protocol commitments or the package-owned empty-root constant.
Wrapping a context is the intended way to route a zkVM accelerator or count
node hashes for tests and benchmarks.

## Scope

The generic lane accepts raw byte keys; the fixed lane accepts `FixedKey`; the
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

The fuzz gate generates shared-prefix, divergent, and prefix-chain tries and
requires sorted, unsorted, exact-size-workspace, and sparse-from-empty
construction to agree on one root. It also round-trips generated leaf proofs,
checks witness-backed replace and delete, differentially checks fixed-key index
and catalog mutation against full construction, and feeds arbitrary encoded
nodes and keys through proof lookup.

Run from the repository root:

```sh
zig build test-packages
zig build fuzz-mpt                 # run the seed corpus
zig build fuzz-mpt --fuzz=10000    # run the builtin fuzzer
```

The unpublished package harness verifies the MPT-to-RLP dependency boundary:

```sh
cd pkg/mpt
zig build test
zig build fuzz
```

## License

Licensed under either the [Apache License, Version 2.0](LICENSE-APACHE) or the
[MIT license](LICENSE-MIT), at your option.
