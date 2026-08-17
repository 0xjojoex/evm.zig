//! Standalone Ethereum modified Merkle Patricia Trie (MPT).
//!
//! The package computes trie roots, resolves inclusion/exclusion proofs, and
//! applies sparse updates to a witness-backed trie. The trie retains a
//! caller-provided allocator, so native callers may grow while guests may use
//! fixed or bump allocation. Operation workspace is derived from actual input.
//! The trie is generic over a Keccak execution context so native and zkVM
//! backends can implement the same fixed structural commitment rule.
//!
//! This is a stateless root/proof/update engine, not a persistent trie
//! database. One engine per capability:
//!
//! | capability            | module         | entry points                    |
//! |-----------------------|----------------|---------------------------------|
//! | construct from scratch| `root.zig`     | `rootSorted`/`root`, exact flat workspace |
//! | authenticated reads   | `proof.zig`    | `lookup`, allocation-free       |
//! | mutate arbitrary keys | `sparse.zig`   | `updateSorted` — variable-width structural keys |
//! | mutate fixed keys     | `occurrence.zig` | `updateFixedSorted`/`updateCatalogSorted` — resolver-backed fixed-64-nibble algebra |
//!
//! `fuzz.zig` differentially checks arbitrary sparse, fixed index, and catalog
//! occurrence mutation against full construction.

const std = @import("std");
const hash = @import("hash.zig");
const root_mod = @import("root.zig");
const proof = @import("proof.zig");
const sparse = @import("sparse.zig");
const occurrence = @import("occurrence.zig");
const catalog = @import("catalog.zig");
const fixed_key = @import("fixed_key.zig");

const errors = @import("error.zig");
pub const Error = errors.Error;
pub const BuildError = errors.BuildError;
pub const IndexError = errors.IndexError;
pub const LookupError = errors.LookupError;
pub const UpdateError = errors.UpdateError;
pub const Root = hash.Root;
pub const FixedKey = fixed_key.FixedKey;
pub const empty_root = hash.empty_root;
pub const StdKeccak256Context = hash.StdKeccak256Context;
pub const RootWorkspace = @import("workspace.zig").Workspace;
pub const Entry = root_mod.Entry;
pub const rootWorkspaceSize = root_mod.workspaceSize;
pub const rootWorkspaceSizeForLimits = root_mod.workspaceSizeForLimits;
pub const Absence = proof.Absence;
pub const Lookup = proof.Lookup;
pub const LookupCache = proof.LookupCache;
pub const NodeIndex = proof.NodeIndex;
pub const Catalog = catalog.Catalog;
pub const CatalogBuilder = catalog.Builder;
pub const CatalogRoot = catalog.RootRef;
pub const CatalogNodeId = catalog.NodeId;
pub const CatalogLimits = catalog.Limits;
pub const CatalogInitError = catalog.InitError;
pub const BoundLookup = catalog.BoundLookup;
pub const BoundValue = catalog.BoundValue;
pub const Region = occurrence.Region;
pub const FixedAbsence = fixed_key.FixedAbsence;
pub const FixedLookup = fixed_key.FixedLookup;
pub const BindWorkspace = fixed_key.BindWorkspace;
pub const BatchLookupError = fixed_key.BatchLookupError;
pub const bindSorted = fixed_key.bindSorted;
pub const bindAssumeSorted = fixed_key.bindAssumeSorted;
/// Final value or deletion for one fixed 32-byte structural key.
pub const FixedUpdate = occurrence.Update;
pub const Update = sparse.Update;

const empty_index_storage: proof.IndexStorage = .{};
pub const empty_node_index = proof.emptyIndex(&empty_index_storage);

const IndexedNodesData = struct {
    allocator: ?std.mem.Allocator,
    storage: []proof.NodeRecord,
    table: []u32,
    index_storage: proof.IndexStorage,
};

var empty_indexed_nodes: IndexedNodesData = .{
    .allocator = null,
    .storage = &.{},
    .table = &.{},
    .index_storage = .{},
};

/// Opaque allocator-owned witness index. Encoded node bytes remain borrowed.
/// The allocator passed to `Trie.init` must outlive this value.
pub const IndexedNodes = opaque {
    pub fn deinit(self: *IndexedNodes) void {
        const data = indexedNodesData(self);
        if (data.allocator) |allocator| {
            allocator.free(data.table);
            allocator.free(data.storage);
            allocator.destroy(data);
        }
    }

    pub fn index(self: *const IndexedNodes) *const NodeIndex {
        return proof.emptyIndex(&indexedNodesConstData(self).index_storage);
    }

    pub fn nodeCount(self: *const IndexedNodes) usize {
        return proof.nodeCount(self.index());
    }

    /// Requested bytes retained by this owned index, excluding allocator
    /// alignment and bookkeeping. Empty indexes use static storage.
    pub fn allocationBytes(self: *const IndexedNodes) usize {
        const data = indexedNodesConstData(self);
        if (data.allocator == null) return 0;
        return @sizeOf(IndexedNodesData) +
            data.storage.len * @sizeOf(proof.NodeRecord) +
            data.table.len * @sizeOf(u32);
    }
};

fn indexedNodesData(indexed: *IndexedNodes) *IndexedNodesData {
    return @ptrCast(@alignCast(indexed));
}

fn indexedNodesConstData(indexed: *const IndexedNodes) *const IndexedNodesData {
    return @ptrCast(@alignCast(indexed));
}

fn indexedNodesFromData(data: *IndexedNodesData) *IndexedNodes {
    return @ptrCast(data);
}

pub const AllocBuildError = std.mem.Allocator.Error || BuildError;
pub const AllocIndexError = std.mem.Allocator.Error || IndexError;
pub const AllocUpdateError = std.mem.Allocator.Error || UpdateError;

/// Trie operations bound to an allocator and a Keccak execution context, which
/// must expose `keccak256(self, []const u8) [32]u8`. The algorithm is not
/// customizable: the context only selects how canonical Keccak-256 executes.
/// The allocator must outlive the trie and its `IndexedNodes`.
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
        ) AllocBuildError!Root {
            return self.buildRoot(entries, true);
        }

        /// Compute the root of a trie built from `entries` in any order; they
        /// are copied into allocator-backed scratch and sorted before building.
        pub fn root(
            self: Self,
            entries: []const Entry,
        ) AllocBuildError!Root {
            return self.buildRoot(entries, false);
        }

        fn buildRoot(
            self: Self,
            entries: []const Entry,
            already_sorted: bool,
        ) AllocBuildError!Root {
            if (entries.len == 0) return empty_root;
            const needed = try root_mod.requirements(entries);
            const scratch_len = try root_mod.workspaceSizeFor(entries.len, needed, !already_sorted);
            const scratch = try self.allocator.alloc(u8, scratch_len);
            defer self.allocator.free(scratch);
            var workspace = RootWorkspace.init(scratch);
            return if (already_sorted)
                root_mod.rootSorted(self.keccak_context, &workspace, entries, needed)
            else
                root_mod.root(self.keccak_context, &workspace, entries, needed);
        }

        /// Advanced fixed-scratch variant of `rootSorted`.
        pub fn rootSortedWithWorkspace(
            self: Self,
            workspace: *RootWorkspace,
            entries: []const Entry,
        ) BuildError!Root {
            return root_mod.rootSorted(self.keccak_context, workspace, entries, try root_mod.requirements(entries));
        }

        /// Advanced fixed-scratch variant of `root`.
        pub fn rootWithWorkspace(
            self: Self,
            workspace: *RootWorkspace,
            entries: []const Entry,
        ) BuildError!Root {
            return root_mod.root(self.keccak_context, workspace, entries, try root_mod.requirements(entries));
        }

        /// Hash each encoded witness node and index them by hash into an
        /// allocator-owned sealed index for use by `lookup` and `updateSorted`.
        pub fn indexNodes(
            self: Self,
            encoded_nodes: []const []const u8,
        ) AllocIndexError!*IndexedNodes {
            if (encoded_nodes.len == 0) {
                return indexedNodesFromData(&empty_indexed_nodes);
            }

            const storage = try self.allocator.alloc(proof.NodeRecord, encoded_nodes.len);
            errdefer self.allocator.free(storage);
            const table = try self.allocator.alloc(u32, proof.tableCapacity(encoded_nodes.len));
            errdefer self.allocator.free(table);
            const data = try self.allocator.create(IndexedNodesData);
            errdefer self.allocator.destroy(data);
            data.* = .{
                .allocator = self.allocator,
                .storage = storage,
                .table = table,
                .index_storage = .{},
            };
            _ = proof.indexNodes(self.keccak_context, &data.index_storage, storage, table, encoded_nodes) catch |err| switch (err) {
                error.WorkspaceTooSmall => unreachable,
                error.ConflictingNode => return error.ConflictingNode,
            };
            return indexedNodesFromData(data);
        }

        /// Resolve `key` against the witness index rooted at `root_hash`,
        /// returning the stored value or the reason the key is absent.
        pub fn lookup(
            _: Self,
            root_hash: Root,
            index: *const NodeIndex,
            key: []const u8,
        ) LookupError!Lookup {
            return proof.lookup(root_hash, index, key);
        }

        /// Apply `updates` (sorted ascending by key; a null value deletes the
        /// key) to the witness trie rooted at `root_hash` and return the new
        /// root. Insertions precede deletions; hashed children are materialized
        /// from the index only when the combined update still needs them.
        pub fn updateSorted(
            self: Self,
            root_hash: Root,
            index: *const NodeIndex,
            updates: []const Update,
        ) AllocUpdateError!Root {
            return sparse.updateSorted(
                self.keccak_context,
                self.allocator,
                root_hash,
                index,
                updates,
            );
        }

        /// Apply sorted fixed-32-byte-key updates through the shared mutation
        /// engine, resolving authenticated nodes lazily from the sealed index.
        /// Scratch comes from the caller's region and is rewound before return.
        pub fn updateFixedSorted(
            self: Self,
            region: *Region,
            root_hash: Root,
            index: *const NodeIndex,
            updates: []const FixedUpdate,
        ) AllocUpdateError!Root {
            return occurrence.updateIndexSorted(
                self.keccak_context,
                region,
                root_hash,
                index,
                updates,
            );
        }

        /// Apply sorted fixed-key updates through an authenticated catalog.
        /// Scratch comes from the caller's region and is rewound before return.
        pub fn updateCatalogSorted(
            self: Self,
            region: *Region,
            topology: *const Catalog,
            catalog_root: CatalogRoot,
            updates: []const FixedUpdate,
        ) AllocUpdateError!Root {
            return occurrence.updateCatalogSorted(
                self.keccak_context,
                region,
                topology,
                catalog_root,
                updates,
            );
        }

        /// Start a root-scoped authenticated catalog over an existing sealed
        /// witness index. Additional state or storage roots may be linked
        /// before `CatalogBuilder.finish` seals the immutable topology.
        pub fn catalogBuilder(self: Self, index: *const NodeIndex) std.mem.Allocator.Error!CatalogBuilder {
            return catalog.Builder.init(self.allocator, index);
        }

        /// Admission-bounded catalog ingestion. A surrounding application may
        /// fall back to proof lookup when a sealed witness exceeds its budget.
        pub fn catalogBuilderWithLimits(
            self: Self,
            index: *const NodeIndex,
            limits: CatalogLimits,
        ) CatalogInitError!CatalogBuilder {
            return catalog.Builder.initWithLimits(self.allocator, index, limits);
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

                pub const Entry = struct {
                    key: Key,
                    value: []const u8,
                };

                pub const Update = struct {
                    key: Key,
                    value: ?[]const u8,
                };

                structural: StructuralTrie,
                key_context: KeyContext,

                pub fn init(structural: StructuralTrie, key_context: KeyContext) KeyedSelf {
                    return .{ .structural = structural, .key_context = key_context };
                }

                /// Project each typed key, then sort by the projected key.
                /// Domain-key ordering cannot be reused because projection may
                /// not preserve order.
                pub fn root(self: KeyedSelf, entries: []const KeyedSelf.Entry) AllocBuildError!Root {
                    const allocator = self.structural.allocator;
                    const projected_keys = try allocator.alloc(FixedKey, entries.len);
                    defer allocator.free(projected_keys);
                    const structural_entries = try allocator.alloc(root_mod.Entry, entries.len);
                    defer allocator.free(structural_entries);

                    for (entries, 0..) |entry, index| {
                        projected_keys[index] = self.key_context.trieKey(entry.key);
                        structural_entries[index] = .{
                            .key = &projected_keys[index],
                            .value = entry.value,
                        };
                    }
                    return self.structural.root(structural_entries);
                }

                /// Fixed-size projection stays on the stack, so lookup remains
                /// allocation-free after witness indexing.
                pub fn lookup(
                    self: KeyedSelf,
                    root_hash: Root,
                    index: *const NodeIndex,
                    key: Key,
                ) LookupError!Lookup {
                    const projected_key = self.key_context.trieKey(key);
                    return self.structural.lookup(root_hash, index, &projected_key);
                }

                /// Project and sort the batch before fixed-key mutation through
                /// the sealed witness index.
                /// Colliding projections are reported as `DuplicateKey`.
                /// Scratch comes from the caller's region and is rewound before return.
                pub fn update(
                    self: KeyedSelf,
                    region: *Region,
                    root_hash: Root,
                    index: *const NodeIndex,
                    updates: []const KeyedSelf.Update,
                ) AllocUpdateError!Root {
                    const mark = region.mark();
                    defer region.rewind(mark);
                    const allocator = region.allocator();
                    const structural_updates = try allocator.alloc(occurrence.Update, updates.len);

                    for (updates, structural_updates) |item, *projected| {
                        projected.* = .{
                            .key = self.key_context.trieKey(item.key),
                            .value = item.value,
                        };
                    }
                    sortFixedUpdates(structural_updates);
                    return self.structural.updateFixedSorted(region, root_hash, index, structural_updates);
                }

                pub fn updateCatalog(
                    self: KeyedSelf,
                    region: *Region,
                    topology: *const Catalog,
                    catalog_root: CatalogRoot,
                    updates: []const KeyedSelf.Update,
                ) AllocUpdateError!Root {
                    const mark = region.mark();
                    defer region.rewind(mark);
                    const allocator = region.allocator();
                    const structural_updates = try allocator.alloc(occurrence.Update, updates.len);

                    for (updates, structural_updates) |item, *projected| {
                        projected.* = .{
                            .key = self.key_context.trieKey(item.key),
                            .value = item.value,
                        };
                    }
                    sortFixedUpdates(structural_updates);
                    return self.structural.updateCatalogSorted(
                        region,
                        topology,
                        catalog_root,
                        structural_updates,
                    );
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

/// Allocation-free proof lookup. The witness index and encoded node bytes must
/// remain alive for the duration of the call.
pub fn lookup(root_hash: Root, index: *const NodeIndex, key: []const u8) LookupError!Lookup {
    return proof.lookup(root_hash, index, key);
}

pub fn lookupCached(
    root_hash: Root,
    index: *const NodeIndex,
    key: []const u8,
    cache: *LookupCache,
) (std.mem.Allocator.Error || LookupError)!Lookup {
    return proof.lookupCached(root_hash, index, key, cache);
}
