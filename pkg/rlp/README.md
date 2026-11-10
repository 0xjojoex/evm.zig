# rlp

Strict Recursive Length Prefix (RLP) encoding and decoding for Zig 0.17.

## Install

`rlp` is exported by [`evmz`](../../README.md), fetched as a single root package:

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
exe.root_module.addImport("rlp", evmz.module("rlp"));
```

## Quick start

```zig
const rlp = @import("rlp");

// Non-allocating encode/decode into caller storage (borrowed slices point into `written`).
const written = try rlp.encode(Account, out, &account);
const decoded = try rlp.decode(Account, written);

// Single-allocation encode and budgeted owned decode.
const encoded = try rlp.encodeAlloc(Account, allocator, &account);
defer allocator.free(encoded);

var owned = try rlp.decodeAlloc(Account, allocator, encoded);
defer rlp.deinit(Account, allocator, &owned);
```

`encode` and `decode` are the default calling convention: name a Zig type and
`rlp` resolves the wire format from `@typeInfo(T)`, or from a type-owned
`T.Rlp` declaration when present.

### Explicit codecs

When a value's RLP meaning is not inferable from its type — or requires a
specific application wire projection — pass a codec to `encodeAs` / `decodeAs`:

```zig
const written = try rlp.encodeAs(CustomCodec, out, value);
const value = try rlp.decodeAs(CustomCodec, written);
```

Codecs are schema sugar for custom projections and bounds, not a prerequisite
for ordinary types.

## Default type mappings

| Zig type                        | RLP meaning                                                       |
| ------------------------------- | ----------------------------------------------------------------- |
| unsigned integer through `u256` | minimal big-endian integer byte string                            |
| `bool`                          | false as empty bytes, true as `0x01`                              |
| `void`                          | empty byte string; never omission                                 |
| `[N]u8`                         | exact byte string preserving leading zeroes                       |
| `[]const u8`                    | borrowed variable byte string                                     |
| `[]u8`                          | variable byte string; `decodeAlloc` returns an owned mutable copy |
| `[N]T`, `T != u8`               | exact-length RLP list                                             |
| `[]const T`, `T != u8`          | homogeneous RLP list                                              |
| plain or tuple struct           | declaration-order RLP list                                        |
| `?T`, `T` never empty           | Ethereum's absent-as-empty-byte-string convention                 |

Both values and single-value pointers are accepted at the encoding boundary.

Signed integers, enums, unions, non-byte mutable slices, packed/extern structs,
and non-slice pointers require an explicit codec or a type-owned `Rlp`
declaration.

An optional infers `Optional(T)`, where `null` is the empty byte string. That
is unambiguous only when `T`'s codec can never encode to the empty byte string:
`?[N>0]u8`, `?Address`, `?SomeStruct`, and `?[]const T` infer automatically,
whereas `?u64`, `?bool`, and `?[]const u8` fail at comptime because `0`,
`false`, and `""` would decode back as `null`. Custom codecs declare this
property with `pub const may_encode_empty` (defaulting to `true`).

## Lower-level surfaces

Three layers sit under the type-driven API:

- **Raw parsing** — borrowed `Item` / `Cursor` traversal plus `Writer`.
- **Runtime-shaped lists** — `encodeList` / `encodeListAlloc` for lists whose
  fields depend on runtime branches.
- **Reusable codecs** — `Struct`, `ArrayOf`, `ListOf`, `BoundedListOf`,
  `FixedBytes`, `Optional`, `Mapped`, and `Raw`.

The `Raw` codec recursively validates nested items against depth, item-count,
and allocation budgets. Decode it with `decodeAllocAs(rlp.Raw, ...)`; the
returned `Item` still borrows its encoded bytes and owns no payload storage.

### Building runtime-shaped lists

Pass a deterministic emitter function to `encodeList` or `encodeListAlloc`:

```zig
const bytes = try rlp.encodeListAlloc(struct {
    pub fn emit(fields: anytype, tx: Tx) !void {
        try fields.encode(u64, tx.nonce);
        try fields.encode([]const u8, tx.input);
    }
}.emit, allocator, tx);
defer allocator.free(bytes);
```

Inside an emitter, the `fields` sink supports four operations:

- `fields.encode(T, value)` — inferred meaning (encodes a struct as a nested RLP list).
- `fields.encodeAs(Codec, value)` — explicit wire projection.
- `fields.encodeFields(T, value)` — splices a struct's fields into the current
  list without a nested list prefix.
- `fields.list(emit, value)` — nests another runtime-shaped list.

The emitter runs twice (once to measure payload length, once to write) and must
be side-effect-free; a measured/written length mismatch fails with
`error.EncodedLengthMismatch`. `encodeListAlloc` performs one exact allocation.

## Memory and ownership

- `encode` / `encodeList` write directly into caller-provided buffers;
  `encodeAlloc` / `encodeListAlloc` allocate once at the exact encoded size.
- Decoded `[]const u8` slices borrow from the input buffer (even inside a
  struct or list decoded via `decodeAlloc`), so keep the input alive until
  `deinit`. Use `[]u8` when you want `decodeAlloc` to allocate an owned copy.
- `decodeWithBudget` and `decodeAllocWithBudget` take a caller-owned `Budget`
  capping nesting depth, visited items, and total allocated bytes.
- `ListOf(T).View` iterates homogeneous lists without allocating a slice when
  the element codec is non-allocating.

Errors are partitioned into `ParseError`, `ValidationError`, `EncodeError`, and
`DecodeError`.

## Conformance

The package is self-contained: ordinary builds have no fixture download or
package-specific lockfile. Two small raw corpora under `src/fixtures/` are
vendored extracts from `ethereum/tests/RLPTests`; their source and extraction
policy are recorded beside the files. High-value typed and long-length cases
from `ethereum/ethereum-rlp` are translated into ordinary Zig tests instead of
tracking the upstream Python test surface.

Byte, boolean, integer, fixed-byte, struct, tuple, sequence, canonicality,
truncation, trailing-input, and length-boundary behavior is covered locally.
EEST transaction and block fixtures remain application integration gates rather
than codec conformance substitutes.

Run from the repository root:

```sh
zig build test-packages
zig build fuzz-rlp
```

The unpublished package harness keeps an isolated development lane:

```sh
cd pkg/rlp
zig build test
zig build fuzz
```

## License

Licensed under either the [Apache License, Version 2.0](LICENSE-APACHE) or the
[MIT license](LICENSE-MIT), at your option.
