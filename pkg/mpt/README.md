# mpt

Structural Ethereum Merkle Patricia Trie primitives for Zig 0.17 — canonical
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

## Choosing a representation

Most trie libraries sit behind a persistent database. A stateless executor
receives a trusted root and a sealed bag of witness nodes: it must authenticate
available topology once, serve repeated reads without rehashing or re-decoding,
and compute a post-state root under caller-controlled memory.

`mpt` provides three lanes so each workload pays only for what it uses:

| Lane | Key width | Witness ingestion | Read entry point | Mutation entry point | Best for |
| --- | --- | --- | --- | --- | --- |
| Generic / sparse | Arbitrary `[]const u8` | `Trie.indexWitness` | `WitnessIndex.lookup` | `Trie.updateSorted` | Variable-length keys, conformance tests, one-off proofs |
| Fixed-key witness | `FixedKey` (`[32]u8`) | `Trie.indexWitness` | `WitnessIndex.lookup` | `Trie.updateFixedSorted(witnessSource, ...)` | Hashed 32-byte keys without pre-linking a catalog |
| Authenticated catalog | `FixedKey` (`[32]u8`) | `Catalog.Builder` over `WitnessIndex` | `Catalog.lookup` / `Catalog.bindSorted` | `Trie.updateFixedSorted(catalogSource, ...)` | Stateless block execution: link reachable nodes once, then run zero-hash, zero-RLP-decode reads and batch updates |

Optional `NodeUpdates` output retains each dirty root or hashed child as its
already-computed digest plus encoded bytes (embedded `< 32`-byte children remain
inline in their parent encoding).

## Install

`mpt` is exported by [`evmz`](../../README.md), fetched as a single root package:

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

Depends only on the Zig standard library and the sibling `rlp` module (wired
automatically by the root package).

## Quick start

```zig
const mpt = @import("mpt");
const trie = mpt.init(allocator);

// 1. Build a canonical root from key/value entries (std Keccak-256).
const entries = [_]mpt.Entry{
    .{ .key = "do",    .value = "verb" },
    .{ .key = "dog",   .value = "puppy" },
    .{ .key = "horse", .value = "stallion" },
};
const root_hash = try trie.root(&entries);

// 2. Verify a key against a trusted root using a sealed witness index.
var witness = try trie.indexWitness(encoded_nodes);
defer witness.deinit();

switch (try witness.lookup(trusted_root, "dog")) {
    .present => |value| { /* authenticated value bytes borrowed from `encoded_nodes` */ },
    .absent  => |reason| { /* valid non-existence proof (`Absence` tag) */ },
}

// 3. Recompute a post-root from sorted updates without materializing the whole trie.
const updates = [_]mpt.Update{
    .{ .key = "do",  .value = null },    // delete
    .{ .key = "dog", .value = "hound" }, // insert/replace
};
const post_root = try trie.updateSorted(trusted_root, witness, &updates);
```

`mpt.init(allocator)` uses the stdlib Keccak-256 implementation. To route
hashing through a native or zkVM accelerator, construct
`mpt.Trie(MyKeccakContext).init(allocator, context)` where `MyKeccakContext`
implements `pub fn keccak256(self, input: []const u8) mpt.Root`.

Operations that hash (`root`, `indexWitness`, `update*`) live on `Trie`.
Hash-free reads live on the indexed data (`WitnessIndex.lookup`,
`Catalog.lookup`, `Catalog.bindSorted`).

### Typed domain keys (`Keyed`)

Project domain keys (such as `Address` or `u256`) into `mpt.FixedKey` (`[32]u8`)
while keeping values as raw bytes:

```zig
const Structural = mpt.Trie(MyKeccak);
const Accounts = Structural.Keyed(Address, AccountKeyContext);
const accounts = Accounts.init(structural_trie, account_key_context);

const result = try accounts.lookup(root_hash, witness, address);
```

`KeyContext.trieKey(self, key)` owns only the key projection; it does not encode
values or alter node hashing.

## Core concepts

### Values and key ordering

- **Non-empty values:** An empty byte string represents absence in Ethereum's
  MPT and is never stored. Map domain defaults (such as a zero storage slot) to
  a delete (`value = null`).
- **Sorting:** A `Sorted` suffix (`rootSorted`, `updateSorted`,
  `updateFixedSorted`, `bindSorted`) validates that keys are strictly ascending
  and unique (`error.UnsortedKeys` / `error.DuplicateKey`). `AssumeSorted` skips
  validation when the caller guarantees ordering; unsuffixed variants (`root`,
  `Keyed.update`) sort for you in scratch memory without copying key or value
  bytes.

### Witness index and lookup outcomes

`Trie.indexWitness` hashes each borrowed node slice once and seals an opaque
`*WitnessIndex` (open-addressed at `<= 50%` load; identical duplicates
collapsed; conflicting bytes for the same digest rejected; extra unreferenced
nodes ignored).

`WitnessIndex.lookup` returns `Lookup` (and allocation-free repeated reads can
pass a `LookupCache` to `lookupCached`):

- `.present` — authenticated value slice borrowed from the witness input.
- `.absent` — valid exclusion proof tagged with `Absence` (`empty_trie`,
  `divergent_path`, `missing_branch_child`, or `empty_branch_value`).
- `error.MissingNode` — a required hashed node was omitted from the witness.

### Authenticated catalog and fixed-key mutations

- **Catalog (`Catalog.Builder`):** Links reachable witness nodes from one or
  more roots into stable `u32` handles without rehashing, rejecting cycles and
  noncanonical extension topology on `finish()`. Subsequent `Catalog.lookup`,
  `Catalog.lookupBound`, and batch `Catalog.bindSorted` calls perform no
  hashing, digest search, allocation, or RLP decoding.
- **Fixed-key overlay (`updateFixedSorted`):** Accepts `witnessSource(index, root)`
  or `catalogSource(topology, root)` plus a `ScopedArenaAllocator`. It
  materializes mutable nodes only along updated 64-nibble paths, keeps untouched
  subtrees as authenticated handles, and encodes dirty ancestors once bottom-up.

## Resource model

`init` takes an allocator retained by the trie; `root`, `rootSorted`,
`indexWitness`, and `updateSorted` use it, and it must outlive the trie and
every `WitnessIndex` it creates. Both fixed-key mutation paths take an explicit
`ScopedArenaAllocator`; the typed `update` facade also allocates its projected
update descriptors there.

The primary API has no caller-supplied limits: touched topology grows
incrementally through the allocator rather than reserving a speculative
worst case, so a normal heap grows while a fixed or bump allocator enforces
the caller's chosen envelope. Arithmetic or representability overflow returns
`error.ResourceLimitExceeded`; allocator exhaustion returns
`error.OutOfMemory`. Untrusted input admission belongs at the surrounding wire
or application boundary — the stateless guest, for example, validates SSZ list
and byte-list maxima before invoking MPT, and its fixed allocator independently
caps memory.

`rootBufferSize(entries, include_sort)`, `rootBufferSizeForLimits`, and the
root `*WithBuffer` entry points remain advanced APIs for exact full-root buffer
reuse; the limits form computes a
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
The catalog is built only after the witness index exists, so it does not replace
wire-level admission bounds on raw witness count and bytes.

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
misaligned/undersized full-root buffer.

The fuzz gate generates shared-prefix, divergent, and prefix-chain tries and
requires sorted, unsorted, exact-size-buffer, and sparse-from-empty
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
