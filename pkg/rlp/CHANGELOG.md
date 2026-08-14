# Changelog

All notable changes to the `rlp` package are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
This is a closed record of the `rlp-v0.1.0` subtree release. The module now
ships at the evmz package version; later entries live in the root
[CHANGELOG.md](../../CHANGELOG.md).

## [0.1.0] - 2026-07-22

### Added

- Initial release: strict RLP encoding and decoding for Zig 0.16.
- Type-directed `encode`/`decode` resolving the wire format from `@typeInfo(T)`
  or a type-owned `T.Rlp` override.
- Explicit codecs via `encodeAs`/`decodeAs` for exact schemas and application
  wire projections.
- Caller-owned output buffers; decoding borrows validated views into the input.
- Fuzz target (`zig build fuzz`) covering the decoder against malformed input.

[0.1.0]: https://github.com/0xjojoex/evm.zig/releases/tag/rlp-v0.1.0
