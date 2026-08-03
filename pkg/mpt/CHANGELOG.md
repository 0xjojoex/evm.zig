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

### Changed

- Lazily materialize hashed branch children.
- Borrow sparse branches during encoding and updates.
- Decode only the selected proof branches.
