# Changelog

All notable changes to the `rlp` package are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases are cut from `pkg/rlp` on evmz `main` and published to the generated
`release/rlp` branch as `rlp-vX.Y.Z`.

## [Unreleased]

### Added

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

### Changed

- Simplified encoding to reduce cycles

### Removed

- `OptionalFixedBytes(N)`. `?[N]u8` infers the same codec, and
  `Optional(FixedBytes(N))` spells it explicitly.

## [0.1.0] - 2026-07-22

### Added

- Initial release: strict RLP encoding and decoding for Zig 0.16.
- Type-directed `encode`/`decode` resolving the wire format from `@typeInfo(T)`
  or a type-owned `T.Rlp` override.
- Explicit codecs via `encodeAs`/`decodeAs` for exact schemas and application
  wire projections.
- Caller-owned output buffers; decoding borrows validated views into the input.
- Fuzz target (`zig build fuzz`) covering the decoder against malformed input.

[Unreleased]: https://github.com/0xjojoex/evm.zig/compare/rlp-v0.1.0...main
[0.1.0]: https://github.com/0xjojoex/evm.zig/releases/tag/rlp-v0.1.0
