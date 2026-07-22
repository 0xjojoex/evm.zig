# SSZ

A comptime-typed [SimpleSerialize (SSZ)](https://github.com/ethereum/consensus-specs/blob/master/ssz/simple-serialize.md)
codec for Zig, built for stateless Ethereum verification and zkVM
guests. Encode and decode against caller-controlled memory, then compute
`hash_tree_root` without retaining a Merkle tree or leaf cache.

```zig
const ssz = @import("ssz");
```

## Install

The package is developed under `pkg/ssz` in
[`0xjojoex/evm.zig`](https://github.com/0xjojoex/evm.zig) and published from
the generated `release/ssz` branch. Add a tagged package root with:

```sh
zig fetch --save=ssz git+https://github.com/0xjojoex/evm.zig#ssz-v0.1.0
```

Then import the dependency's `ssz` module from your `build.zig`. Development
and pull requests belong on evmz `main`; the release branch is generated and
must not be edited directly.

## Why this one

- **Stateless, built for guests.** No allocation and no global state on the hash
  path; zero-subtree roots are embedded constants, so empty and padded subtrees
  cost zero SHA-256 and a zkVM guest proves only the compressions its data needs.
  Any pure or in-circuit SHA-256 context plugs in without touching the schema.
- **Schema is the type.** Codecs are comptime values built from your Zig structs —
  no derive macro, no codegen step, no runtime reflection. Field overrides and
  `Mapped` decouple the wire schema from the host type when they differ.
- **You own the memory.** Encoding writes directly into caller-provided storage;
  borrowing codecs return validated views into the input. Owned decoding allocates
  only when the host representation requires it, and only for the exact length.
- **Fast.** Early same-machine benchmarks put owned decoding at parity with or
  ahead of LambdaClass Rust [`libssz`](https://github.com/lambdaclass/libssz),
  while caller-buffer encoding provides a dedicated zero-allocation lane. See
  [Performance notes](#performance-notes).
- **Unopinionated backing.** The core stays flat and cache-free, but `walkTree`
  replays the exact canonical Merkleization node by node — so you can build a
  persistent tree, leaf cache, or incremental re-hashing on top without forking the
  codec. Flat by default; any backing you need above it.

## Quick start

For unambiguous fixed-size values (bools, ints, arrays, plain structs) the eager
API needs no schema:

```zig
const encoded = ssz.encode(value);          // owned, exact size
const decoded = try ssz.decode(Value, &encoded);

var buf: [ssz.encodedSize(Value)]u8 = undefined;
ssz.encodeInto(&buf, value);                // no allocation
const from_bytes = try ssz.decodeSlice(Value, runtime_bytes);
```

Variable-size and Ethereum-specific shapes use an explicit codec. Attach it to
your struct as a `Ssz` decl:

```zig
const Payload = struct {
    parent: Header,
    extra_data: []const u8,
    withdrawals: []const Withdrawal,

    pub const Ssz = ssz.Container(Payload, .{
        .extra_data = ssz.ByteList(32),
        .withdrawals = ssz.List(Withdrawal, 16),
    });
};

var payload = try Payload.Ssz.decodeAlloc(allocator, bytes);
defer Payload.Ssz.deinit(allocator, &payload);

const root = try ssz.hashTreeRoot(Payload.Ssz, payload);
```

`Container(@This(), .{})` is the schema entry point for a data-model struct. An
empty override set means every field is inferred through the host-type mapping;
you list only the fields whose Zig type doesn't pin down the SSZ schema.

## What it supports

Every SSZ shape and the codec that produces it. Shapes the host-type mapping
below can infer come for free; the rest you name explicitly.

| SSZ type                         | Codec                                                                               |
| -------------------------------- | ----------------------------------------------------------------------------------- |
| `bool`, `uintN` (8–256)          | eager, no schema                                                                    |
| `Vector[T, N]` (fixed element)   | plain `[N]T` array                                                                  |
| `Vector[T, N]` (any element)     | `VectorOf(Codec, N)`                                                                |
| `Bitvector[N]` / `Bitlist[N]`    | `Bitvector(N)` / `Bitlist(N)`                                                       |
| `List[byte, N]`                  | `ByteList(N)`                                                                       |
| `List[T, N]` (fixed element)     | `List(T, N)`                                                                        |
| `List[T, 1]` represented as `?T` | `OptionalList(T)`                                                                   |
| `List[T, N]` (any element)       | `ListOf(Codec, N)`                                                                  |
| `Container`                      | `Container(T, overrides)`                                                           |
| `Union`                          | `Union(T, overrides)`                                                               |
| `CompatibleUnion`                | `CompatibleUnion(T, config)`                                                        |
| Progressive collections          | `ProgressiveList`, `ProgressiveListOf`, `ProgressiveByteList`, `ProgressiveBitlist` |
| `ProgressiveContainer`           | `ProgressiveContainer(T, active_fields, overrides)`                                 |
| Existing schema, different host  | `Mapped(Host, WireCodec, mapping)`                                                  |

`Alloc(Codec)` keeps a codec's fixed wire schema but materializes decoded values
on the heap — the practical choice for preset-sized fields (e.g. a blob) that
would otherwise be megabytes on the stack.

`hashTreeRoot` covers every shape above, including sparse progressive containers
and both union forms, without allocating intermediate roots.

Bounded variable-size codecs (`ByteList`, `List`, `ListOf`, and `Bitlist`) keep
their declared capacity as an arbitrary-precision `comptime_int`. A schema such
as `ByteList(1 << 120)` can therefore encode and hash a small runtime slice
without narrowing its Merkle tree to `usize`. Only actual element counts,
serialized byte lengths, and allocator operations use machine-sized integers.

## Host-type mapping

Everything above is the "what"; this is the "how it's chosen." When a field has
no explicit codec, the schema is inferred from its Zig type.

`Container(T, overrides)` resolves each field codec in this order:

1. An explicit entry in `overrides`.
2. The field type's `pub const Ssz` declaration.
3. The package's `codecFor(FieldType)` default.

There is no global codec registry. A field override is needed only when the Zig
type does not fully express the intended SSZ schema, or when an external wire
format deliberately uses a non-default representation.

| Zig host type                             | Default SSZ schema | Notes                                                                                               |
| ----------------------------------------- | ------------------ | --------------------------------------------------------------------------------------------------- |
| `bool`                                    | `boolean`          | Only `0` and `1` decode successfully.                                                               |
| `u8`, `u16`, `u32`, `u64`, `u128`, `u256` | matching `uintN`   | Signed and non-standard integer widths are rejected at comptime.                                    |
| `enum(uN)`                                | its `uintN` tag    | Equivalent to `IntEnum(E)`; decoding rejects integers with no declared enum value.                  |
| `[N]T`                                    | `Vector[T, N]`     | `N` is known from the type; element codecs are resolved recursively. Empty vectors are invalid SSZ. |
| non-empty `struct` without `Ssz`          | `Container`        | Field codecs are resolved recursively; tuples and comptime fields are rejected.                     |
| `T` with `pub const Ssz`                  | `T.Ssz`            | The type-owned schema is used before structural inference.                                          |
| `?T`                                      | `Union[None, T]`   | Package convention for an optional value: selector `0` is `None`, selector `1` is `T`.              |

These shapes do **not** receive a guessed default:

| Zig host type                   | Why it needs an explicit codec                                                                           |
| ------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `[]T`, `[]const T`              | The type does not carry a list maximum, or distinguish a list from allocation-backed vector storage.     |
| bit-packed values               | A Zig array does not distinguish `Vector[bool, N]` from `Bitvector[N]` or `Bitlist[N]`.                  |
| tagged unions                   | Selector order, `None`, and compatibility policy are protocol choices; use `Union` or `CompatibleUnion`. |
| pointers and custom projections | Ownership and wire representation are application choices.                                               |

Ambiguous fields fail at comptime with an instruction to provide an override or
a type-owned `Ssz` declaration. Inference never invents a collection bound.

### Schema overrides

The default mappings are conventions, not requirements imposed on external
schemas. Use a field override when the Zig host type is still appropriate but
the protocol assigns that field a different SSZ type. The override selects the
complete field codec used for encoding, decoding, validation, and
hash-tree-root calculation.

Optional values are a useful example. The package maps `?T` to
`Union[None, T]` by default:

```text
null     -> 0x00
value T  -> 0x01 || encode(T, value)
```

Instead you can represent some domain-level optional values as `List[T, 1]`:

```text
null     -> empty list
value T  -> one-element list containing T
```

Even though `?T` remains the natural Zig representation, state the difference at the field with
`OptionalList(T)`:

```zig
const ForkActivation = struct {
    block_number: ?u64,
    timestamp: ?u64,

    // This uses List[uint64, 1], not Union.
    pub const Ssz = ssz.Container(@This(), .{
        .block_number = ssz.OptionalList(u64),
        .timestamp = ssz.OptionalList(u64),
    });
};
```

For a different in-memory representation of an existing SSZ schema, use
`Mapped(Host, WireCodec, mapping)`. The wire codec remains authoritative for
layout, validation, allocation, and hash-tree-root; the mapping only converts
the host value:

```zig
const Slot = struct {
    value: u64,

    fn toWire(value: @This()) u64 {
        return value.value;
    }

    fn fromWire(value: u64) @This() {
        return .{ .value = value };
    }

    pub const Ssz = ssz.Mapped(@This(), ssz.Fixed(u64), .{
        .toWire = toWire,
        .fromWire = fromWire,
    });
};
```

Mappings must be infallible, lossless, and ownership-preserving: both
`fromWire(toWire(host))` and `toWire(fromWire(wire))` must retain their input
value. Allocator-backed mappings must retain the decoded allocations so the
wire codec can release them through `deinit`. Mappings are for representational
differences, not custom validation or non-SSZ serialization.

### Enums

SSZ has no enum basic type; a Zig `enum(uN)` is an application representation
over `uintN`. It maps automatically (row above), keeping that integer schema
while rejecting unknown tags on decode. Use `IntEnum(E)` when you need the same
mapping stated explicitly — as a field override, or as a standalone codec for a
bare enum.

## Owning vs. non-owning

- Non-allocating codecs expose `decode(bytes)`.
- Allocating codecs expose `decodeAlloc(allocator, bytes)` and
  `deinit(allocator, value)`.
- Generic callers can use `ssz.decodeOwned` / `ssz.deinitOwned`, which dispatch
  at comptime and no-op for non-owning codecs.
- `ssz.encodeAlloc(Codec, allocator, value)` is the convenience adapter when you
  want an exact-size owned buffer; otherwise `Codec.encode(out, value)` writes
  into storage you provide. Input and output must not overlap.

Note that a value's wire layout and its Zig representation are independent: a
131072-byte `Vector` is fixed-size on the wire yet can still be decoded into an
allocated slice via `Alloc`.

## Custom hashing provider

`hashTreeRoot` defaults to `StdSha256Context`. To supply your own SHA-256,
implement a context with a single `hash64` method and build a `Merkleizer`:

```zig
const AcceleratedSha256Context = struct {
    provider: *Provider,
    pub fn hash64(self: @This(), input: *const [64]u8) [32]u8 {
        return self.provider.sha256(input);
    }
};

const merkleizer = ssz.Merkleizer(AcceleratedSha256Context).init(.{
    .provider = provider,
});
const root = try merkleizer.hashTreeRoot(Payload.Ssz, payload);
```

The context attaches only to Merkleization; encoding, decoding, and schemas stay
provider-independent. Contexts must implement canonical SHA-256 as a pure result
provider. Zero-subtree roots through depth 255 are generated ahead of time and
embedded as canonical constants, so those operations do not call `hash64`;
deeper schemas extend the same sequence through the supplied context. The
256-root table is an 8 KiB speed prefix, not a schema-depth limit.

## Testing & benchmarks

```sh
cd pkg/ssz
zig build test
zig build -Doptimize=ReleaseFast bench
zig build -Doptimize=ReleaseFast bench -- --filter list_u64
```

The canonical zero-root table is a checked-in binary artifact. Regenerate it
explicitly after changing its size or generation rules:

```sh
zig run tools/generate-zero-roots.zig -- src/merkle/zero_roots.bin
```

From the evmz repo root, `zig build ssz-bench` runs the same matrix. Benchmarks
cover primitives, vectors, containers, large `u64` lists, and a Phase 0
`BeaconState` at 16K/100K validators, reporting median time and throughput.

### Performance notes

Early Apple M1 Max results (`ReleaseFast`, median):

| Workload                                             | This package | `libssz` |
| ---------------------------------------------------- | -----------: | -------: |
| Encode `List[u64, 1K]`, caller buffer                |       102 ns |        - |
| Decode `List[u64, 1K]`, owned                        |       140 ns |   134 ns |
| Encode `List[u64, 100K]`, caller buffer              |      12.8 us |        - |
| Decode `List[u64, 100K]`, owned                      |      13.5 us |  13.4 us |
| Encode `BeaconState`, 16K validators, caller buffer  |       149 us |        - |
| Decode `BeaconState`, 16K validators, owned          |       168 us |   166 us |
| Encode `BeaconState`, 100K validators, caller buffer |       555 us |        - |
| Decode `BeaconState`, 100K validators, owned         |       564 us |   620 us |

`-` means `libssz` has no equivalent arbitrary caller-buffer API or upstream
`BeaconState` benchmark lane. Its `ssz_append` API can retain `Vec` capacity,
but that is a different output contract. In the directly comparable owned
decode lane, large lists are at parity; `BeaconState` is at parity at 16K
validators and about 1.1x faster at 100K. These are early local measurements,
not a performance guarantee. `hashTreeRoot` is excluded because results depend
heavily on the SHA-256 provider.

### Tradeoff

This package does not optimize for a long-lived mutable state that is re-rooted
after every update. We keep caching _out_ of the codec on purpose. Because
`hashTreeRoot` is a pure function over `(schema, value)`, a caller can back it
with a persistent tree, a leaf cache, or incremental re-hashing.
`Merkleizer(HashContext).walkTree` exposes the same visitor with a custom
SHA-256.

```zig
const TreeVisitor = struct {
    pub const Error = MyPersistentTree.Error;
    tree: *MyPersistentTree,

    pub fn visit(self: *@This(), path: *const ssz.TreePath, node: ssz.TreeNode) Error!void {
        try self.tree.putCopiedPath(path, node);
    }
};

var visitor = TreeVisitor{ .tree = &tree };
const root = try ssz.walkTree(Payload.Ssz, payload, &visitor);
```
