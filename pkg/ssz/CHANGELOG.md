# Changelog

All notable changes to the `ssz` package are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases are cut from `pkg/ssz` on evmz `main` and published to the generated
`release/ssz` branch as `ssz-vX.Y.Z`.

## [Unreleased]

### Added

- Borrowed SSZ views and packed bitfields.
- Borrowed Merkle child roots on the `hash_tree_root` path.

### Changed

- Consolidated borrowed decoding onto a single codec surface.

## [0.1.0] - 2026-07-22

### Added

- Initial release: comptime-typed SimpleSerialize codec for Zig 0.16.
- Encoding into caller-provided storage; owned decoding allocates only for the
  exact length the host representation requires.
- Allocation-free `hash_tree_root` with embedded zero-subtree constants, so
  empty and padded subtrees cost zero SHA-256 compressions.
- Pluggable SHA-256 context for native and in-circuit (zkVM guest) backends.
- Schema overrides and `Mapped` for decoupling the wire schema from the host
  type.
- Verified against the `ethereum/consensus-specs` SSZ corpus
  (`zig build ssz-conformance`).

[Unreleased]: https://github.com/0xjojoex/evm.zig/compare/ssz-v0.1.0...main
[0.1.0]: https://github.com/0xjojoex/evm.zig/releases/tag/ssz-v0.1.0
