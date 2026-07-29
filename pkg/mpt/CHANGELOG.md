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

### Changed

- Lazily materialize hashed branch children.
- Borrow sparse branches during encoding and updates.
- Decode only the selected proof branches.
