# SSZ

A comptime-typed [SimpleSerialize (SSZ)](https://github.com/ethereum/consensus-specs/blob/master/ssz/simple-serialize.md)
codec for Zig, built for stateless Ethereum verification and zkVM
guests. Encode and decode against caller-controlled memory, then compute
`hash_tree_root` without retaining a Merkle tree or leaf cache.

```zig
const ssz = @import("ssz");
```

## Install

`ssz` is one of the modules exported by
[`evmz`](https://github.com/0xjojoex/evm.zig), which is fetched as a single
package:

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
exe.root_module.addImport("ssz", evmz.module("ssz"));
```

The historical `ssz-v0.1.0` tag and the `release/ssz` branch remain reachable
for existing consumers, but no new package-prefixed releases are cut.

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
- **Fast.** Owned decoding matches or beats LambdaClass Rust
  [`libssz`](https://github.com/lambdaclass/libssz) on the same boundary, and
  packed one-shot `hash_tree_root` runs about 5x faster end to end. Where the
  representation is yours to choose, borrowed and packed lanes are 25x to
  ~2300x over their expanded equivalents. See [Performance](#performance).
- **Unopinionated backing.** The core stays flat and cache-free, but `walkTree`
  replays the exact canonical Merkleization node by node — so a persistent tree,
  leaf cache, or incremental re-hashing goes on top without forking the codec.

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
below can infer are free; the rest you name explicitly.

| SSZ type                         | Codec                                                                               |
| -------------------------------- | ----------------------------------------------------------------------------------- |
| `bool`, `uintN` (8–256)          | eager, no schema                                                                    |
| `Vector[T, N]` (fixed element)   | plain `[N]T` array                                                                  |
| `Vector[T, N]` (any element)     | `VectorOf(Codec, N)`                                                                |
| `Bitvector[N]` / `Bitlist[N]`    | `Bitvector(N)` / `Bitlist(N)`, or packed borrowed variants                          |
| `List[byte, N]`                  | `ByteList(N)`                                                                       |
| `List[T, N]` (fixed element)     | `List(T, N)`                                                                        |
| `List[T, 1]` represented as `?T` | `OptionalList(T)`                                                                   |
| `List[T, N]` (any element)       | `ListOf(Codec, N)`                                                                  |
| `Container`                      | `Container(T, overrides)`                                                           |
| `Union`                          | `Union(T, overrides)`                                                               |
| `CompatibleUnion`                | `CompatibleUnion(T, config)`                                                        |
| Progressive collections          | `ProgressiveList`, `ProgressiveListOf`, `ProgressiveByteList`, `ProgressiveBitlist` |
| `ProgressiveContainer`           | `ProgressiveContainer(T, active_fields, overrides)`                                 |
| Existing schema, different host  | `Mapped(Host, WireCodec, Mapping)`                                                  |

`Alloc(Codec)` keeps a codec's fixed wire schema but materializes decoded values
on the heap — the practical choice for preset-sized fields (e.g. a blob) that
would otherwise be megabytes on the stack.

`hashTreeRoot` covers every shape above, including sparse progressive containers
and both union forms, without allocating intermediate roots.

Bounded variable-size codecs (`ByteList`, `List`, `ListOf`, `Bitlist`) hold
their capacity as an arbitrary-precision `comptime_int`, so `ByteList(1 << 120)`
encodes and hashes a small runtime slice without narrowing its Merkle tree to
`usize`. Only element counts, byte lengths, and allocations are machine-sized.

## Host-type mapping

When a field has no explicit codec, its schema is inferred from its Zig type.
`Container(T, overrides)` resolves each field codec in this order:

1. An explicit entry in `overrides`.
2. The field type's `pub const Ssz` declaration.
3. The package's `codecFor(FieldType)` default.

There is no global codec registry. Override a field only when its Zig type does
not fully express the intended SSZ schema, or when an external wire format
deliberately uses a non-default representation.

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
schemas. Use a field override when the Zig host type is still right but the
protocol assigns that field a different SSZ type. The override supplies the
complete field codec — encoding, decoding, validation, and hash-tree-root.

Optionals are the common case. `?T` maps to `Union[None, T]`:

```text
null     -> 0x00
value T  -> 0x01 || encode(T, value)
```

Some protocols use `List[T, 1]` instead:

```text
null     -> empty list
value T  -> one-element list containing T
```

`?T` is still the natural Zig type; state the difference at the field:

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
`Mapped(Host, WireCodec, Mapping)`. The wire codec remains authoritative for
layout, validation, allocation, and hash-tree-root; the mapping only converts
the host value:

```zig
const Slot = struct {
    value: u64,

    const WireMapping = struct {
        pub fn toWire(value: Slot) u64 {
            return value.value;
        }

        pub fn fromWire(value: u64) Slot {
            return .{ .value = value };
        }
    };

    pub const Ssz = ssz.Mapped(@This(), ssz.Fixed(u64), WireMapping);
};
```

Mappings must be infallible, lossless, and ownership-preserving: both
`fromWire(toWire(host))` and `toWire(fromWire(wire))` must retain their input
value, and an allocator-backed mapping must keep the decoded allocations
reachable for `deinit`. They express representational differences, not custom
validation or non-SSZ serialization.

### Enums

SSZ has no enum type; a Zig `enum(uN)` is an application representation over
`uintN`. It maps automatically, keeping that integer schema and rejecting
unknown tags on decode. `IntEnum(E)` states the same mapping explicitly — as a
field override, or as a standalone codec for a bare enum.

## Owning vs. non-owning

- Non-allocating codecs expose `decode(bytes)`.
- Allocating codecs expose `decodeAlloc(allocator, bytes)` and
  `deinit(allocator, value)`.
- Generic callers can use `ssz.decodeOwned` / `ssz.deinitOwned`, which dispatch
  at comptime and no-op for non-owning codecs.
- `ssz.Borrowed(Codec)` selects an allocating codec's input-backed `decode`
  capability while preserving its ordinary value shape and SSZ schema.
- `ssz.encodeAlloc(Codec, allocator, value)` is the convenience adapter when you
  want an exact-size owned buffer; otherwise `Codec.encode(out, value)` writes
  into storage you provide. Input and output must not overlap.

Note that a value's wire layout and its Zig representation are independent: a
131072-byte `Vector` is fixed-size on the wire yet can still be decoded into an
allocated slice via `Alloc`.

### Borrowed decoding

Borrowed decoding is opt-in, for inputs that already have a stable lifetime.
`Borrowed(Codec)` is not a universal zero-copy switch: it accepts only an
allocating codec that also exposes an input-backed `decode(bytes)` with the same
`Value`. Today that means:

- `ByteList(limit)`
- `ProgressiveByteList`
- `Mapped` codecs whose wire codec preserves that capability

Apply `Borrowed` at those leaves, then compose them normally:

```zig
const Items = ssz.ListOf(ssz.Borrowed(ssz.ByteList(32)), 1_000);
var items = try ssz.decodeOwned(Items, allocator, encoded_items);
defer ssz.deinitOwned(Items, allocator, &items);
const first = items[0]; // borrows encoded_items
```

`ListOf` and `ProgressiveListOf` still allocate their outer element slice;
only the byte payloads borrow from the input. Containers, inline vectors,
optionals, unions, and mapped host representations compose transitively and
allocate according to their remaining field codecs.

Codecs that already decode without allocation — basic values, `ByteVector`,
`Bitvector`, `OptionalList` — should be used directly. Slice-backed vectors,
fixed-element lists, expanded `Bitlist` values, and outer `ListOf` storage have
no input-backed representation with the same `Value`, so `Borrowed` rejects
them.

The `PackedBitvector`, `PackedBitlist`, and `ProgressivePackedBitlist` codecs
are already borrowed codecs; do not wrap them in `Borrowed`. They retain
canonical packed bytes and expose semantic bits through `PackedBitsView`:

```zig
const Flags = ssz.PackedBitlist(4_096);
const flags = try Flags.decode(encoded_flags);
if (flags.isSet(7)) {
    // read without expanding to one bool per bit
}
```

Keep the backing bytes alive and unchanged for the borrowed value's whole
lifetime; use the base codec's owned decoding when the value must outlive its
input. Packed views are immutable — read, hash, and re-encode; use the boolean
bitfield codecs to mutate.

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
provider-independent. It must implement canonical SHA-256 as a pure function.
Zero-subtree roots through depth 255 ship as embedded constants and never call
`hash64`; deeper schemas extend the same sequence through your context, so the
8 KiB table is a speed prefix, not a schema-depth limit.

## Testing & benchmarks

Run from the repository root:

```sh
zig build test-packages
zig build ssz-bench
zig build ssz-bench -- --filter list_u64
```

The unpublished package harness keeps an isolated development lane:

```sh
cd pkg/ssz
zig build test
zig build bench -- --filter list_u64
```

The canonical zero-root table is a checked-in binary artifact. Regenerate it
explicitly after changing its size or generation rules:

```sh
zig run tools/generate-zero-roots.zig -- src/merkle/zero_roots.bin
```

`ssz-bench` delegates to the sidecar build in `bench/`, which consumes the
repository root with `-Dcore=false` exactly as an external consumer does.
Benchmarks cover primitives, vectors, containers, large `u64` and nested byte lists,
expanded and packed bitfields, and a Phase 0 `BeaconState` at 16K/100K
validators, reporting median time and throughput.

## Performance

- Parity to 1.14x against Rust `libssz` on the directly comparable lanes, with
  one loss: 16K `BeaconState` decode at 0.88x.
- About 5x on packed one-shot `hash_tree_root`, end to end.
- 25x to ~2300x where the host representation is yours to choose — borrowed
  payloads and packed bitfields against their expanded, owned equivalents.

### Cross-library lanes

Local Apple M1 Max results (Zig 0.16.0 `ReleaseFast` median; Rust 1.96.0
Criterion estimate against `libssz`
[`f4d682b`](https://github.com/lambdaclass/libssz/commit/f4d682b238f565c098d6fc43852c7534840328c9)).
Both sides use the same ownership and output boundary. `vs` is the `libssz`
time divided by this package's; above 1.00x is faster here.

| Workload                                        | This package | `libssz` |    vs |
| ----------------------------------------------- | -----------: | -------: | ----: |
| Encode `List[u64, 1K]`, reused output           |       102 ns |   111 ns | 1.09x |
| Encode `List[u64, 1K]`, fresh exact output      |       138 ns |   154 ns | 1.12x |
| Decode `List[u64, 1K]`, owned                   |       137 ns |   156 ns | 1.14x |
| Encode `List[u64, 100K]`, reused output         |      14.3 us |  14.1 us | 0.99x |
| Encode `List[u64, 100K]`, fresh exact output    |      14.1 us |  14.6 us | 1.04x |
| Decode `List[u64, 100K]`, owned                 |      14.2 us |  14.7 us | 1.04x |
| Encode `Bitvector[4096]`, packed, fresh output  |      40.0 ns |  41.5 ns | 1.04x |
| Encode `Bitlist[4096]`, packed, fresh output    |      41.8 ns |  44.6 ns | 1.07x |
| Encode `BeaconState`, 16K validators, reused    |       154 us |        — |     — |
| Decode `BeaconState`, 16K validators, owned     |       170 us |   149 us | 0.88x |
| Encode `BeaconState`, 100K validators, reused   |       553 us |        — |     — |
| Decode `BeaconState`, 100K validators, owned    |       580 us |   619 us | 1.07x |

Reused-output rows time steady-state work with no allocation in the loop: this
package writes into an arbitrary caller slice, `libssz` clears a pre-sized `Vec`
before `ssz_append`. The allocation behavior is comparable, the output API is
not identical. Fresh-output rows allocate and free an exact-size result for
every operation on both sides.

`—` marks a lane with no comparable upstream measurement: the `BeaconState`
fresh-`Vec` encode run was order-sensitive locally. The caller-buffer lane still
reads on its own — a full `BeaconState` serializes into caller memory for less
than the cost of decoding one, with no allocation in the timed path.

### Packed one-shot hash_tree_root

| Workload                      | This package | `libssz` |    vs |
| ----------------------------- | -----------: | -------: | ----: |
| HTR `Bitvector[4096]`, packed |      1.09 us |  5.83 us | 5.3x  |
| HTR `Bitlist[4096]`, packed   |      1.16 us |  6.45 us | 5.6x  |

These are end-to-end operations under each library's default SHA-256 provider
(stdlib here, `Sha2Hasher` upstream). Provider choice can dominate an HTR
result, so read these as default-path numbers rather than codec-only ones.

### Representation lanes

Where a value has more than one host representation, that choice is worth more
than any codec-level margin. Each pair below uses identical encoded bytes and
identical semantic values; only the representation differs.

| Workload                                | Expanded / owned | Packed / borrowed | Speedup |
| --------------------------------------- | ---------------: | ----------------: | ------: |
| Decode `List[ByteList[32], 1K]`         |          28.7 us |           1.14 us |     25x |
| Decode `List[ByteList[32], 100K]`       |          2.88 ms |            105 us |     27x |
| Encode `Bitvector[4096]`, caller buffer |          4.24 us |           7.65 ns |    554x |
| Decode `Bitvector[4096]`                |          2.48 us |           1.09 ns |  ~2300x |
| HTR `Bitvector[4096]`, stdlib SHA-256   |          5.12 us |           1.09 us |    4.7x |
| Encode `Bitlist[4096]`, caller buffer   |          2.75 us |           8.51 ns |    323x |
| Decode `Bitlist[4096]`                  |          2.45 us |           1.25 ns |  ~1960x |
| HTR `Bitlist[4096]`, stdlib SHA-256     |          3.77 us |           1.16 us |    3.3x |

Borrowed byte-list decoding allocates and frees the outer list index while
retaining each validated payload in the encoded input. Owned decoding also
copies and frees every payload. `libssz` bitfield decoding returns owned packed
storage, which is neither representation above, so these pairs have no upstream
counterpart.

**Method.** One machine, one run each; this package's medians against Criterion
point estimates, with no cross-machine or cross-run normalization. These are
local measurements, not a performance guarantee.

### Tradeoff

This package does not optimize for long-lived mutable state that is re-rooted
after every update; caching stays _out_ of the codec on purpose. Because
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

## License

Licensed under either the [Apache License, Version 2.0](LICENSE-APACHE) or the
[MIT license](LICENSE-MIT), at your option.
