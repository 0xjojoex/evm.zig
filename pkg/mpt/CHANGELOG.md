# Changelog

All notable changes to the `mpt` package are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases are cut from `pkg/mpt` on evmz `main` and published to the generated
`release/mpt` branch as `mpt-vX.Y.Z`.

## [Unreleased]

### Added

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
- Fixed-32-byte-key mutation through either a sealed witness index
  (`updateFixedSorted`) or authenticated catalog (`updateCatalogSorted`) using
  the shared `FixedUpdate` representation and mutation algebra. Catalog updates
  use a caller-owned `Region`; both resolvers materialize only selected paths,
  preserve untouched authenticated references, and recompute dirty ancestors
  bottom-up.
- Allocation-free fixed-32-byte-key batch binding (`bindSorted`),
  walking integer links over an authenticated catalog and sharing prefixes
  between sorted state and storage keys with a fixed `BindWorkspace`.
- `IndexedNodes.allocationBytes` reports bytes retained by an owned index, so
  guests can budget fixed or bump allocation.

### Changed

- Curated catalog and fixed-key APIs at the package root instead of exposing
  representation modules. Root construction scratch is named `RootWorkspace`;
  fixed-key binding uses `BindWorkspace`; catalog mutation uses `Region`.
- Fixed key projection contexts now have an exact
  `trieKey(self, Key) FixedKey` contract, matching the exact
  `keccak256(self, []const u8) Root` execution-context contract.
- Lazily materialize hashed branch children.
- Borrow sparse branches during encoding and updates.
- Decode only the selected proof branches.
