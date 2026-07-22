# rlp

Standalone strict RLP Recursive Length Prefix encoding and decoding library for Zig 0.16

## Install

The package is developed under `pkg/rlp` in
[`0xjojoex/evm.zig`](https://github.com/0xjojoex/evm.zig) and published from
the generated `release/rlp` branch. Add a tagged package root with:

```sh
zig fetch --save=rlp git+https://github.com/0xjojoex/evm.zig#rlp-v0.1.0
```

Then import the dependency's `rlp` module from your `build.zig`. Development
and pull requests belong on evmz `main`; the release branch is generated and
must not be edited directly.

```zig
const written = try rlp.encode(Account, out, &account);
const account = try rlp.decode(Account, written);
```

`encode` and `decode` are the default calling convention: you name a Zig type
and the package resolves the wire format from `@typeInfo(T)`, or from a
type-owned `T.Rlp` override when one is declared. You never spell out a schema
for the common cases.

Explicit codecs

When a value's RLP meaning isn't inferable from its type — or you need a
specific application wire projection — pass a codec instead:

```zig
const written = try rlp.encodeAs(CustomCodec, out, value);
const value = try rlp.decodeAs(CustomCodec, written);
```

Codecs are schema sugar, not a prerequisite. They stay available for exact
schemas and wire projections but are not the top-level default.

## Default type mappings:

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

Both values and single-value pointers are accepted at the encoding boundary.

Signed integers, optionals, enums, unions, non-byte mutable slices,
packed/extern structs, and non-slice pointers require an explicit codec or a
type-owned mapping. RLP cannot guess whether these mean omission, tagging, an
integer policy, or some other application-level representation.

`OptionalFixedBytes(N)` is the explicit Ethereum-style convention where
`null` is an empty byte string and a present value is exactly `N` bytes. It
does not make that convention the inferred meaning of every Zig optional.

## Lower-level surfaces

Three complementary layers sit under the type-driven API:

- **Raw parsing** — borrowed `Item` / `Cursor` traversal plus the
  migration-friendly `Writer`.
- **Runtime-shaped lists** — `encodeList` / `encodeListAlloc` for lists whose
  fields are chosen at runtime.
- **Reusable codecs** — exact schemas, bounded lists, raw items, and host/wire
  projections.

The `Raw` codec recursively validates nested items against the same depth,
item-count, and allocation budget. Because arbitrary nesting needs temporary
validation scratch, decode it with `decodeAllocAs`; the returned `Item` still
borrows its encoded bytes and owns no payload storage.

Building runtime-shaped lists

Inside a runtime list, the `fields` helpers mirror the top-level API:

- `fields.encode(T, value)` — same inferred meaning as top-level `encode`;
  encodes a struct as one nested RLP list.
- `fields.encodeAs(Codec, value)` — selects an explicit wire projection.
- `fields.encodeFields(T, value)` — expands a struct's fields into the current
  list _without_ adding a nested prefix.
- `fields.list(emit, value)` — nests a further runtime-shaped list.

## Emitter contract

The top-level emitter runs twice: once to measure, once to write. Nested
emitters may run extra sizing passes to build their own list prefixes. Every
emitter must therefore be deterministic and side-effect-free — a measured/write
length mismatch is rejected. `encodeListAlloc` performs a single exact
top-level allocation.

## Memory and ownership

Codecs write directly into caller storage; `encodeAlloc` performs one exact
top-level allocation. Materialized decoding takes a caller-owned `Budget` that
independently caps nesting depth, visited items, and aggregate storage.
`ListOf(T).View` is the allocation-free path for nonallocating element codecs.

Schema inference maps `[]const u8` to an RLP byte string and other `[]const T`
slices to homogeneous RLP lists; use `BoundedListOf` or a field override when a
size limit or different projection is part of the schema.

Decoded `[]const u8` strings are borrowed from the encoded input — including
fields inside a materialized struct or list — so keep the input alive until
`deinit`. Choosing `[]u8` instead requests an owned copy via `decodeAlloc`.

Errors split into `ParseError`, `ValidationError`, `EncodeError`, and
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

```sh
zig build test
zig build fuzz
```
