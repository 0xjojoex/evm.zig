//! Standalone Ethereum modified Merkle Patricia Trie (MPT).
//!
//! The package computes trie roots, resolves inclusion/exclusion proofs, and
//! applies sparse updates to a witness-backed trie. This is a stateless
//! root/proof/update engine, not a persistent trie database.
//!
//! Operations that execute Keccak — root construction, witness indexing, and
//! every mutation — live on `Trie(KeccakContext)`, which retains the caller's
//! allocator so native callers may grow while guests may use fixed or bump
//! allocation. Hash-free reads live on the data they read: `WitnessIndex`
//! serves proof lookups, `Catalog` serves authenticated linked-topology reads
//! and batch binds.
//!
//! One engine per capability:
//!
//! | capability            | module           | entry points                    |
//! |-----------------------|------------------|---------------------------------|
//! | construct from scratch| `construct.zig`  | `rootSorted`/`root`, exact flat buffer |
//! | authenticated reads   | `proof.zig`      | `WitnessIndex.lookup`, allocation-free |
//! | linked topology reads | `catalog.zig`    | `Catalog.lookup`/`bindSorted` over stable `u32` handles |
//! | mutate arbitrary keys | `sparse.zig`     | `updateSorted` — variable-width structural keys |
//! | mutate fixed keys     | `occurrence.zig` | `updateFixedSorted` over `Source(.witness)`/`Source(.catalog)` — resolver-backed fixed-64-nibble algebra |
//!
//! Naming: a `Sorted` suffix means the input must already be strictly
//! ascending and unique (validated, `error.UnsortedKeys`/`error.DuplicateKey`);
//! `AssumeSorted` means the caller guarantees it; an unsuffixed variant sorts
//! for the caller.
//!
//! `fuzz.zig` differentially checks arbitrary sparse, fixed index, and catalog
//! occurrence mutation against full construction.

const std = @import("std");
const hash = @import("hash.zig");
const construct = @import("construct.zig");
const proof = @import("proof.zig");
const sparse = @import("sparse.zig");
const occurrence = @import("occurrence.zig");
const fixed_key = @import("fixed_key.zig");
pub const nibble = @import("nibble.zig");

const errors = @import("error.zig");
pub const Error = errors.Error;
pub const BuildError = errors.BuildError;
pub const IndexError = errors.IndexError;
pub const LookupError = errors.LookupError;
pub const UpdateError = errors.UpdateError;

pub const Root = hash.Root;
pub const empty_root = hash.empty_root;
pub const StdKeccak256Context = hash.StdKeccak256Context;
pub const Region = occurrence.Region;

pub const Entry = construct.Entry;
pub const Update = sparse.Update;
pub const FixedKey = fixed_key.FixedKey;
pub const FixedUpdate = occurrence.Update;

pub const Lookup = proof.Lookup;
pub const Absence = proof.Absence;
pub const LookupCache = proof.LookupCache;
pub const FixedLookup = fixed_key.FixedLookup;
pub const FixedAbsence = fixed_key.FixedAbsence;

pub const WitnessIndex = proof.WitnessIndex;
pub const Catalog = @import("catalog.zig").Catalog;

/// Which node-resolution source backs a fixed-key mutation batch.
pub const SourceMode = enum { witness, catalog };

/// Fixed-key mutation source: the node resolver plus the root the batch
/// applies to. The value's type selects the engine lane at comptime, so each
/// mutation verb exists once. Construct with `witnessSource`/`catalogSource`.
pub fn Source(comptime mode: SourceMode) type {
    return switch (mode) {
        .witness => struct {
            pub const source_mode: SourceMode = .witness;
            index: *const WitnessIndex,
            root: Root,
        },
        .catalog => struct {
            pub const source_mode: SourceMode = .catalog;
            topology: *const Catalog,
            root: Catalog.Root,
        },
    };
}

pub fn witnessSource(index: *const WitnessIndex, root: Root) Source(.witness) {
    return .{ .index = index, .root = root };
}

pub fn catalogSource(topology: *const Catalog, root: Catalog.Root) Source(.catalog) {
    return .{ .topology = topology, .root = root };
}

fn sourceModeOf(comptime T: type) SourceMode {
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "source_mode") and T == Source(T.source_mode)) {
        return T.source_mode;
    }
    @compileError("expected mpt.Source(.witness) or mpt.Source(.catalog), found " ++ @typeName(T));
}

pub const rootBufferSize = construct.bufferSize;
pub const rootBufferSizeForLimits = construct.bufferSizeForLimits;

/// Trie operations bound to an allocator and a Keccak execution context, which
/// must expose `keccak256(self, []const u8) [32]u8`. The algorithm is not
/// customizable: the context only selects how canonical Keccak-256 executes.
/// The allocator must outlive the trie and every `WitnessIndex` it creates.
pub fn Trie(comptime KeccakContext: type) type {
    comptime hash.assertKeccakContext(KeccakContext);
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        keccak_context: KeccakContext,

        pub fn init(allocator: std.mem.Allocator, keccak_context: KeccakContext) Self {
            return .{ .allocator = allocator, .keccak_context = keccak_context };
        }

        /// Compute the root of a trie built from `entries` already sorted
        /// ascending by key; returns `error.UnsortedKeys` otherwise.
        pub fn rootSorted(
            self: Self,
            entries: []const Entry,
        ) (std.mem.Allocator.Error || BuildError)!Root {
            return self.buildRoot(entries, true);
        }

        /// Compute the root of a trie built from `entries` in any order; the
        /// entry descriptors are copied into allocator-backed scratch and
        /// sorted before building. Key and value bytes are never copied.
        pub fn root(
            self: Self,
            entries: []const Entry,
        ) (std.mem.Allocator.Error || BuildError)!Root {
            return self.buildRoot(entries, false);
        }

        fn buildRoot(
            self: Self,
            entries: []const Entry,
            already_sorted: bool,
        ) (std.mem.Allocator.Error || BuildError)!Root {
            if (entries.len == 0) return empty_root;
            const needed = try construct.requirements(entries);
            const scratch_len = try construct.bufferSizeFor(entries.len, needed, !already_sorted);
            const scratch = try self.allocator.alloc(u8, scratch_len);
            defer self.allocator.free(scratch);
            return if (already_sorted)
                construct.rootSorted(self.keccak_context, scratch, entries, needed)
            else
                construct.root(self.keccak_context, scratch, entries, needed);
        }

        /// Advanced caller-provided-buffer variant of `root`; size the buffer
        /// with `rootBufferSize`/`rootBufferSizeForLimits`.
        pub fn rootWithBuffer(
            self: Self,
            buffer: []u8,
            entries: []const Entry,
        ) BuildError!Root {
            return construct.root(self.keccak_context, buffer, entries, try construct.requirements(entries));
        }

        /// Hash each encoded witness node and seal them into an
        /// allocator-owned index serving lookups and updates.
        pub fn indexWitness(
            self: Self,
            encoded_nodes: []const []const u8,
        ) (std.mem.Allocator.Error || IndexError)!*WitnessIndex {
            return proof.indexWitness(self.keccak_context, self.allocator, encoded_nodes);
        }

        /// Apply `updates` (sorted ascending by key; a null value deletes the
        /// key) to the witness trie rooted at `root_hash` and return the new
        /// root. Insertions precede deletions; hashed children are materialized
        /// from the witness only when the combined update still needs them.
        pub fn updateSorted(
            self: Self,
            root_hash: Root,
            witness: *const WitnessIndex,
            updates: []const Update,
        ) (std.mem.Allocator.Error || UpdateError)!Root {
            return sparse.updateSorted(
                self.keccak_context,
                self.allocator,
                root_hash,
                proof.sealedIndex(witness),
                updates,
            );
        }

        /// Apply sorted fixed-32-byte-key updates through the shared mutation
        /// engine, resolving nodes from `source`: a witness source materializes
        /// authenticated nodes lazily, a catalog source walks pre-authenticated
        /// linked topology.
        /// Scratch comes from the caller's region and is rewound before return.
        pub fn updateFixedSorted(
            self: Self,
            region: *Region,
            source: anytype,
            updates: []const FixedUpdate,
        ) (std.mem.Allocator.Error || UpdateError)!Root {
            return switch (comptime sourceModeOf(@TypeOf(source))) {
                .witness => occurrence.updateIndexSorted(
                    self.keccak_context,
                    region,
                    source.root,
                    proof.sealedIndex(source.index),
                    updates,
                ),
                .catalog => occurrence.updateCatalogSorted(
                    self.keccak_context,
                    region,
                    source.topology,
                    source.root,
                    updates,
                ),
            };
        }

        /// Build a typed-key facade over this configured structural trie.
        /// `KeyContext.trieKey(self, key)` must return the fixed 32-byte key
        /// traversed by the MPT. Values remain raw bytes.
        pub fn Keyed(comptime Key: type, comptime KeyContext: type) type {
            const valid = if (std.meta.hasFn(KeyContext, "trieKey")) blk: {
                const info = @typeInfo(@TypeOf(KeyContext.trieKey)).@"fn";
                break :blk !info.is_var_args and
                    info.params.len == 2 and
                    info.params[0].type != null and
                    info.params[0].type.? == KeyContext and
                    info.params[1].type != null and
                    info.params[1].type.? == Key and
                    info.return_type != null and
                    info.return_type.? == FixedKey;
            } else false;
            if (!valid) {
                @compileError("MPT key context must provide trieKey(self, Key) [32]u8");
            }

            const StructuralTrie = Self;
            return struct {
                const KeyedSelf = @This();

                pub const Update = struct {
                    key: Key,
                    value: ?[]const u8,
                };

                structural: StructuralTrie,
                key_context: KeyContext,

                pub fn init(structural: StructuralTrie, key_context: KeyContext) KeyedSelf {
                    return .{ .structural = structural, .key_context = key_context };
                }

                /// Fixed-size projection stays on the stack, so lookup remains
                /// allocation-free after witness indexing.
                pub fn lookup(
                    self: KeyedSelf,
                    root_hash: Root,
                    witness: *const WitnessIndex,
                    key: Key,
                ) LookupError!Lookup {
                    const projected_key = self.key_context.trieKey(key);
                    return witness.lookup(root_hash, &projected_key);
                }

                /// Project and sort the batch before fixed-key mutation through
                /// `source` (witness or catalog). Domain-key ordering cannot be
                /// reused because projection may not preserve order.
                /// Colliding projections are reported as `DuplicateKey`.
                /// Scratch comes from the caller's region and is rewound before return.
                pub fn update(
                    self: KeyedSelf,
                    region: *Region,
                    source: anytype,
                    updates: []const KeyedSelf.Update,
                ) (std.mem.Allocator.Error || UpdateError)!Root {
                    const mark = region.mark();
                    defer region.rewind(mark);
                    const structural_updates = try self.project(region, updates);
                    return self.structural.updateFixedSorted(region, source, structural_updates);
                }

                fn project(
                    self: KeyedSelf,
                    region: *Region,
                    updates: []const KeyedSelf.Update,
                ) std.mem.Allocator.Error![]FixedUpdate {
                    const structural_updates = try region.allocator().alloc(FixedUpdate, updates.len);
                    for (updates, structural_updates) |item, *projected| {
                        projected.* = .{
                            .key = self.key_context.trieKey(item.key),
                            .value = item.value,
                        };
                    }
                    sortFixedUpdates(structural_updates);
                    return structural_updates;
                }
            };
        }
    };
}

pub fn sortUpdates(items: []Update) void {
    std.mem.sort(Update, items, {}, struct {
        fn lessThan(_: void, lhs: Update, rhs: Update) bool {
            return std.mem.lessThan(u8, lhs.key, rhs.key);
        }
    }.lessThan);
}

fn sortFixedUpdates(items: []FixedUpdate) void {
    std.mem.sort(FixedUpdate, items, {}, struct {
        fn lessThan(_: void, lhs: FixedUpdate, rhs: FixedUpdate) bool {
            return std.mem.lessThan(u8, &lhs.key, &rhs.key);
        }
    }.lessThan);
}

pub const DefaultTrie = Trie(StdKeccak256Context);

/// Construct a trie using the default Keccak-256 context.
pub fn init(allocator: std.mem.Allocator) DefaultTrie {
    return DefaultTrie.init(allocator, .{});
}
