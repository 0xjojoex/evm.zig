# Changelog

All notable changes to the `ssz` package are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
This is a closed record of the `ssz-v0.1.0` subtree release. The module now
ships at the evmz package version; later entries live in the root
[CHANGELOG.md](../../CHANGELOG.md).

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

[0.1.0]: https://github.com/0xjojoex/evm.zig/releases/tag/ssz-v0.1.0
