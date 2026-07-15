//! Standalone Ethereum modified Merkle Patricia Trie (MPT).
//!
//! The package computes trie roots, resolves inclusion/exclusion proofs, and
//! applies sparse updates to a witness-backed trie. The trie retains a
//! caller-provided allocator, so native callers may grow while guests may use
//! fixed or bump allocation. Operation workspace is derived from actual input.
//! The trie is generic over a Keccak execution context so native and zkVM
//! backends can implement the same fixed structural commitment rule.
//!
//! This is a stateless root/proof/update engine, not a persistent trie database.

const std = @import("std");
const hash = @import("hash.zig");
const root_mod = @import("root.zig");
const proof = @import("proof.zig");
const sparse = @import("sparse.zig");

const errors = @import("error.zig");
pub const Error = errors.Error;
pub const BuildError = errors.BuildError;
pub const IndexError = errors.IndexError;
pub const LookupError = errors.LookupError;
pub const UpdateError = errors.UpdateError;
pub const Root = hash.Root;
pub const empty_root = hash.empty_root;
pub const StdKeccak256Context = hash.StdKeccak256Context;
pub const Workspace = @import("workspace.zig").Workspace;
pub const Entry = root_mod.Entry;
pub const rootWorkspaceSize = root_mod.workspaceSize;
pub const Absence = proof.Absence;
pub const Lookup = proof.Lookup;
pub const NodeIndex = proof.NodeIndex;
pub const Update = sparse.Update;

const empty_index_storage: proof.IndexStorage = .{};
pub const empty_node_index = proof.emptyIndex(&empty_index_storage);

const IndexedNodesData = struct {
    allocator: ?std.mem.Allocator,
    storage: []proof.NodeRecord,
    index_storage: proof.IndexStorage,
};

const empty_indexed_nodes: IndexedNodesData = .{
    .allocator = null,
    .storage = &.{},
    .index_storage = .{},
};

/// Opaque allocator-owned witness index. Encoded node bytes remain borrowed.
/// The allocator passed to `Trie.init` must outlive this value.
pub const IndexedNodes = opaque {
    pub fn deinit(self: *IndexedNodes) void {
        const data = indexedNodesData(self);
        if (data.allocator) |allocator| {
            allocator.free(data.storage);
            allocator.destroy(data);
        }
    }

    pub fn index(self: *const IndexedNodes) *const NodeIndex {
        return proof.emptyIndex(&indexedNodesData(self).index_storage);
    }

    pub fn nodeCount(self: *const IndexedNodes) usize {
        return proof.nodeCount(self.index());
    }
};

fn indexedNodesData(indexed: *const IndexedNodes) *IndexedNodesData {
    return @ptrCast(@alignCast(@constCast(indexed)));
}

fn indexedNodesFromData(data: *IndexedNodesData) *IndexedNodes {
    return @ptrCast(data);
}

pub const AllocError = std.mem.Allocator.Error || Error;
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
            try root_mod.validateEntries(entries, already_sorted);
            const needed = try root_mod.requirements(entries);
            const scratch_len = try root_mod.workspaceSizeFor(entries.len, needed, !already_sorted);
            const scratch = try self.allocator.alloc(u8, scratch_len);
            defer self.allocator.free(scratch);
            var workspace = Workspace.init(scratch);
            return if (already_sorted)
                root_mod.rootSorted(self.keccak_context, &workspace, entries, needed)
            else
                root_mod.root(self.keccak_context, &workspace, entries, needed);
        }

        /// Advanced fixed-scratch variant of `rootSorted`.
        pub fn rootSortedWithWorkspace(
            self: Self,
            workspace: *Workspace,
            entries: []const Entry,
        ) BuildError!Root {
            return root_mod.rootSorted(self.keccak_context, workspace, entries, try root_mod.requirements(entries));
        }

        /// Advanced fixed-scratch variant of `root`.
        pub fn rootWithWorkspace(
            self: Self,
            workspace: *Workspace,
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
                return indexedNodesFromData(@constCast(&empty_indexed_nodes));
            }
            const storage = try self.allocator.alloc(proof.NodeRecord, encoded_nodes.len);
            errdefer self.allocator.free(storage);
            const data = try self.allocator.create(IndexedNodesData);
            errdefer self.allocator.destroy(data);
            data.* = .{
                .allocator = self.allocator,
                .storage = storage,
                .index_storage = .{},
            };
            _ = proof.indexNodes(self.keccak_context, &data.index_storage, storage, encoded_nodes) catch |err| switch (err) {
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
        /// root, materializing hashed children from the index as needed.
        pub fn updateSorted(
            self: Self,
            root_hash: Root,
            index: *const NodeIndex,
            updates: []const Update,
        ) AllocUpdateError!Root {
            if (updates.len == 0) return root_hash;
            try sparse.validateUpdates(updates, true);
            return sparse.updateSorted(
                self.keccak_context,
                self.allocator,
                root_hash,
                index,
                updates,
            );
        }

        /// Build a typed-key facade over this configured structural trie.
        /// `KeyContext.trieKey(self, key)` must return the fixed 32-byte key
        /// traversed by the MPT. Values remain raw bytes.
        pub fn Keyed(comptime Key: type, comptime KeyContext: type) type {
            if (!std.meta.hasFn(KeyContext, "trieKey")) {
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
                    const projected_keys = try allocator.alloc(Root, entries.len);
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

                pub fn indexNodes(
                    self: KeyedSelf,
                    encoded_nodes: []const []const u8,
                ) AllocIndexError!*IndexedNodes {
                    return self.structural.indexNodes(encoded_nodes);
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

                /// Project and sort the batch before structural sparse update.
                /// Colliding projections are reported as `DuplicateKey`.
                pub fn update(
                    self: KeyedSelf,
                    root_hash: Root,
                    index: *const NodeIndex,
                    updates: []const KeyedSelf.Update,
                ) AllocUpdateError!Root {
                    const allocator = self.structural.allocator;
                    const projected_keys = try allocator.alloc(Root, updates.len);
                    defer allocator.free(projected_keys);
                    const structural_updates = try allocator.alloc(sparse.Update, updates.len);
                    defer allocator.free(structural_updates);

                    for (updates, 0..) |item, projected_index| {
                        projected_keys[projected_index] = self.key_context.trieKey(item.key);
                        structural_updates[projected_index] = .{
                            .key = &projected_keys[projected_index],
                            .value = item.value,
                        };
                    }
                    std.mem.sort(sparse.Update, structural_updates, {}, updateLessThan);
                    return self.structural.updateSorted(root_hash, index, structural_updates);
                }

                fn updateLessThan(_: void, lhs: sparse.Update, rhs: sparse.Update) bool {
                    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
                }
            };
        }
    };
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

/// Advanced fixed-scratch `rootSorted` using the default Keccak context.
pub fn rootSortedWithWorkspace(workspace: *Workspace, entries: []const Entry) BuildError!Root {
    return root_mod.rootSorted(StdKeccak256Context{}, workspace, entries, try root_mod.requirements(entries));
}

/// Advanced fixed-scratch `root` using the default Keccak context.
pub fn rootWithWorkspace(workspace: *Workspace, entries: []const Entry) BuildError!Root {
    return root_mod.root(StdKeccak256Context{}, workspace, entries, try root_mod.requirements(entries));
}
