# Changelog

All notable changes to the evmz package — every module it exports, and the
build options it accepts — are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases follow [the release policy](https://github.com/0xjojoex/evm.zig/blob/main/RELEASING.md).

`pkg/rlp/CHANGELOG.md` and `pkg/ssz/CHANGELOG.md` are closed records of the
`0.1.0` subtree releases.

## [Unreleased]

### Package

- evmz is released as one Zig package at the repository root. `rlp`, `mpt`, and
  `ssz` ship at the package version instead of being split into standalone
  package trees, and unreleased entries from their changelogs move here.
- `-Dcore=false` exports `rlp`, `mpt`, and `ssz` without configuring the EVM
  core, and the native precompile dependencies (ckzg, blst, mcl) are lazy, so a
  module-only consumer fetches no C sources.
- Removed the subtree split script and its workflow. The published
  `rlp-v0.1.0` and `ssz-v0.1.0` tags and their release branches stay reachable.
- Retained unpublished `0.0.0` package harnesses for focused tests, fuzzers,
  benchmarks, and dependency-boundary checks. Root consumers and releases use
  only the root package identity and version.
- Consolidated guest evidence into the existing `zkevm` command and one
  `evidence.json`, removed the dormant SP1 workflow branches and Python report
  stage, and made guest releases promote one explicit strict-run artifact.
  Fixture roots travel in the resolved corpus manifest, and the `rev8` scan
  joined `check-guest-elf`.

### RLP

Added

- `decodeInto`/`decodeIntoAs` decode a nonallocating value directly into
  caller-owned storage, leaving the destination undefined on failure.
- `listEncodedLen` sizes a list from its payload length, so callers can reserve
  exact output storage before encoding.
- `Optional(InnerCodec)` encodes `null` as the empty byte string, and `?T` now
  infers it whenever the inner codec can never encode that same empty byte
  string. Codecs report the property with `pub const may_encode_empty`, which
  defaults to `true` for codecs that stay silent.
- `Cursor.peek`/`Decoder.peek` parse the next item without consuming it or
  charging the decode budget.

Changed

- Simplified encoding to reduce cycles.

Removed

- `OptionalFixedBytes(N)`. `?[N]u8` infers the same codec, and
  `Optional(FixedBytes(N))` spells it explicitly.

### MPT

First appearance of the module; it had no subtree release.

Added

- Structural Ethereum Merkle Patricia Trie primitives: canonical roots, proof
  verification against a sealed witness, and sparse updates over raw byte keys.
- Caller-owned allocator policy, so guests can use fixed or bump allocation.
- Caller-supplied Keccak-256 execution context for native and zkVM backends,
  with a stdlib default.
- Verified against the official `ethereum/tests/TrieTests` corpus.
- Authenticated witness catalog (`Catalog`, `Trie.catalogBuilder`): immutable
  topology linked once from a sealed witness index, then served without
  hashing, index search, allocation, or RLP decoding. Hashed children absent
  from the witness stay opaque authenticated references.
- Catalog-backed sparse updates (`updateCatalog`, `updateSortedCatalog`, and
  their `Batch`/`WithWorkspace` forms) over a reusable
  `CatalogUpdateWorkspace`.
- Block-local stateless mutation and commit (`updateStatelessCatalog`,
  `StatelessWorkspace`, `StatelessUpdate`): mutable occurrences are created
  only for selected paths, untouched children stay authenticated references,
  and one post-state root is recomputed bottom-up.
- Allocation-free fixed-32-byte-key batch binding (`fixed_key.bindSorted`),
  walking integer links over an authenticated catalog and sharing prefixes
  between sorted state and storage keys.
- `IndexedNodes.allocationBytes` reports bytes retained by an owned index, so
  guests can budget fixed or bump allocation.

Changed

- Lazily materialize hashed branch children.
- Borrow sparse branches during encoding and updates.
- Decode only the selected proof branches.

### SSZ

Added

- Borrowed SSZ views and packed bitfields.
- Borrowed Merkle child roots on the `hash_tree_root` path.

Changed

- Consolidated borrowed decoding onto a single codec surface.
- `Mapped` takes its mapping as a namespace type with `pub fn toWire`/`fromWire`
  instead of a struct of function pointers, so one `WireMapping` declaration now
  serves both `ssz.Mapped` and `rlp.Mapped`.
