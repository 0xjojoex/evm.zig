//! Fixed-key mutation over authenticated catalog or sealed-index sources.
//!
//! Source resolution differs, while mutable occurrences, fixed-64-nibble MPT algebra,
//! untouched references, and bottom-up dirty encoding remain shared.

const std = @import("std");
const ScopedArenaAllocator = @import("stdx").ScopedArenaAllocator;

const Catalog = @import("catalog.zig").Catalog;
const encode = @import("encode.zig");
const errors = @import("error.zig");
const fixed_key = @import("fixed_key.zig");
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");
const node_codec = @import("node.zig");
const proof = @import("proof.zig");

const Allocator = std.mem.Allocator;
const UpdateError = errors.UpdateError;
const AllocUpdateError = Allocator.Error || UpdateError;

/// Owned content-addressed dirty nodes from one commitment candidate.
///
/// Root and hashed-child encodings are packed into one byte buffer and paired
/// with the digest already computed by mutation. Embedded children are carried
/// by their parent encoding and therefore do not appear independently.
pub const NodeUpdates = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    ranges: std.ArrayList(Range) = .empty,

    const Range = struct {
        digest: hash.Root,
        start: usize,
        len: usize,
    };

    pub const Entry = struct {
        digest: hash.Root,
        bytes: []const u8,
    };

    pub fn init(allocator: Allocator) NodeUpdates {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NodeUpdates) void {
        self.ranges.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const NodeUpdates) usize {
        return self.ranges.items.len;
    }

    pub fn at(self: *const NodeUpdates, index: usize) Entry {
        const range = self.ranges.items[index];
        return .{
            .digest = range.digest,
            .bytes = self.bytes.items[range.start..][0..range.len],
        };
    }

    fn append(self: *NodeUpdates, digest: hash.Root, encoded: []const u8) Allocator.Error!void {
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(self.allocator, encoded);
        errdefer self.bytes.shrinkRetainingCapacity(start);
        try self.ranges.append(self.allocator, .{
            .digest = digest,
            .start = start,
            .len = encoded.len,
        });
    }
};

/// Final value or deletion for one fixed 32-byte structural key.
pub const Update = struct {
    key: fixed_key.FixedKey,
    value: ?[]const u8,
};

const OccurrenceId = enum(u32) { _ };

const Reference = encode.Reference;

const Parent = union(enum) {
    root,
    extension: OccurrenceId,
    branch: struct {
        node: OccurrenceId,
        child_index: u8,
    },
};

const SourceMode = enum { catalog, index };

const IndexSource = struct {
    reference: node_codec.Reference,
    require_branch: bool,
    root: bool = false,
};

fn Source(comptime mode: SourceMode) type {
    return if (mode == .catalog) Catalog.NodeId else IndexSource;
}

fn BranchSource(comptime mode: SourceMode) type {
    return if (mode == .catalog) *const Catalog.Node else *const node_codec.Node.Branch;
}

fn MutableNode(comptime mode: SourceMode) type {
    return struct {
        kind: Kind,
        parent: Parent,
        reference: Reference = .unset,
        dirty: bool = false,

        const Kind = union(enum) {
            empty,
            sealed: hash.Root,
            source: Source(mode),
            leaf: Leaf,
            extension: Extension,
            branch: Branch,
        };

        const Leaf = struct {
            path: nibble.Path,
            value: []const u8,
        };

        const Extension = struct {
            path: nibble.Path,
            child: OccurrenceId,
        };

        const Branch = struct {
            source: ?BranchSource(mode),
            children: [16]Child,

            // Invariant: every update key is exactly 64 nibbles, so no valid key
            // can terminate at a branch. A variable-width update key would
            // invalidate this representation.
            pub const empty = Branch{
                .source = null,
                .children = [_]Child{.empty} ** 16,
            };
        };

        const Child = union(enum) {
            empty,
            source,
            // The union already occupies eight bytes. Align its only payload so
            // branch child arrays can use natural RV64 word loads without growing.
            occurrence: OccurrenceId align(8),

            comptime {
                std.debug.assert(@sizeOf(Child) == 8);
                std.debug.assert(@alignOf(Child) == 8);
            }
        };
    };
}

const key_nibbles = fixed_key.key_nibbles;
const max_path_nodes = fixed_key.max_path_nodes;

comptime {
    // Fixed 32-byte keys admit at most 64 ancestors plus one leaf.
    std.debug.assert(max_path_nodes <= std.math.maxInt(u7));
}

const DeleteFrame = union(enum) {
    extension: OccurrenceId,
    branch: struct {
        node: OccurrenceId,
        child_index: u8,
    },
};

const EncodeFrame = struct {
    node: OccurrenceId,
    expanded: bool,
    is_root: bool,
};

fn indexSource(reference: node_codec.Reference, require_branch: bool) ?IndexSource {
    return switch (reference) {
        .empty => null,
        .embedded, .hashed => .{ .reference = reference, .require_branch = require_branch },
    };
}

const CatalogNode = MutableNode(.catalog);

comptime {
    std.debug.assert(@sizeOf(CatalogNode.Kind) == 144);
    std.debug.assert(@alignOf(CatalogNode.Kind) == 8);
    std.debug.assert(@sizeOf(CatalogNode) == 192);
    std.debug.assert(@alignOf(CatalogNode) == 8);
}

fn Context(
    comptime KeccakContext: type,
    comptime mode: SourceMode,
    comptime Updates: type,
) type {
    return struct {
        const Self = @This();
        const Occurrence = MutableNode(mode);
        const SourceResolver = if (mode == .catalog) *const Catalog else *const proof.NodeIndex;

        allocator: Allocator,
        keccak_context: KeccakContext,
        source_resolver: SourceResolver,
        node_updates: Updates,
        nodes: std.ArrayList(Occurrence) = .empty,
        compact_buffer: std.ArrayList(u8) = .empty,
        node_buffer: std.ArrayList(u8) = .empty,

        fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.compact_buffer.deinit(self.allocator);
            self.node_buffer.deinit(self.allocator);
        }

        fn occurrence(self: *Self, id: OccurrenceId) *Occurrence {
            const index = @intFromEnum(id);
            std.debug.assert(index < self.nodes.items.len);
            return &self.nodes.items[index];
        }

        fn newOccurrence(
            self: *Self,
            kind: Occurrence.Kind,
            parent: Parent,
            reference: Reference,
            dirty: bool,
        ) Allocator.Error!OccurrenceId {
            if (self.nodes.items.len > std.math.maxInt(u32)) return error.OutOfMemory;
            const id: OccurrenceId = @enumFromInt(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .kind = kind,
                .parent = parent,
                .reference = reference,
                .dirty = dirty,
            });
            return id;
        }

        fn alloc(self: *Self, comptime T: type, len: usize) Allocator.Error![]T {
            return self.allocator.alloc(T, len);
        }

        fn buffers(self: *Self, compact_len: usize, node_len: usize) Allocator.Error!struct {
            compact: []u8,
            node: []u8,
        } {
            try self.compact_buffer.resize(self.allocator, compact_len);
            try self.node_buffer.resize(self.allocator, node_len);
            return .{
                .compact = self.compact_buffer.items,
                .node = self.node_buffer.items,
            };
        }

        fn materialize(self: *Self, id: OccurrenceId) AllocUpdateError!void {
            const source = switch (self.occurrence(id).kind) {
                .source => |source| source,
                .sealed => return error.MissingNode,
                else => return,
            };
            if (comptime mode == .catalog) return self.materializeCatalog(id, source);
            return self.materializeIndex(id, source);
        }

        fn materializeCatalog(self: *Self, id: OccurrenceId, source: Catalog.NodeId) AllocUpdateError!void {
            const topology = self.source_resolver;
            const entry = topology.node(source) orelse return error.InvalidNodeReference;
            switch (entry.kind) {
                .leaf => {
                    const path = entry.path() orelse return error.InvalidNode;
                    self.occurrence(id).kind = .{ .leaf = .{
                        .path = compactPath(path),
                        .value = entry.value() orelse return error.InvalidNode,
                    } };
                },
                .extension => {
                    const path = entry.path() orelse return error.InvalidNode;
                    const link = entry.extensionChild() orelse return error.InvalidNodeReference;
                    const reference = try topology.extensionReference(source);
                    const child = try self.appendCatalogDeferred(link, reference, .{ .extension = id });
                    self.occurrence(id).kind = .{ .extension = .{
                        .path = compactPath(path),
                        .child = child,
                    } };
                },
                .branch => {
                    if (entry.value() != null) return error.NonCanonicalNode;
                    const source_branch = try topology.branchFromNode(entry);
                    var branch = Occurrence.Branch.empty;
                    branch.source = entry;
                    for (source_branch.links, 0..) |link, child_index| {
                        if (link != .empty) branch.children[child_index] = .source;
                    }
                    self.occurrence(id).kind = .{ .branch = branch };
                },
            }
        }

        fn materializeIndex(self: *Self, id: OccurrenceId, source: IndexSource) AllocUpdateError!void {
            const encoded = switch (source.reference) {
                .empty => return error.InvalidNodeReference,
                .hashed => |digest| encoded: {
                    const found = proof.find(self.source_resolver, digest.*) orelse return error.MissingNode;
                    if (!source.root and found.len < 32) return error.InvalidNodeReference;
                    break :encoded found;
                },
                .embedded => |value| value,
            };
            switch (try node_codec.decode(encoded, source.require_branch)) {
                .leaf => |leaf| self.occurrence(id).kind = .{ .leaf = .{
                    .path = compactPath(leaf.path),
                    .value = leaf.value,
                } },
                .extension => |extension| {
                    const child = try self.appendIndexSource(
                        indexSource(extension.child, true) orelse return error.InvalidNodeReference,
                        .{ .extension = id },
                    );
                    self.occurrence(id).kind = .{ .extension = .{
                        .path = compactPath(extension.path),
                        .child = child,
                    } };
                },
                .branch => |branch| {
                    const owned = try self.allocator.create(node_codec.Node.Branch);
                    owned.* = branch;
                    try self.installIndexBranch(id, owned);
                },
            }
        }

        fn installIndexBranch(
            self: *Self,
            id: OccurrenceId,
            source: *const node_codec.Node.Branch,
        ) AllocUpdateError!void {
            if (source.value != null) return error.NonCanonicalNode;
            var branch = Occurrence.Branch.empty;
            branch.source = source;
            for (&branch.children, 0..) |*child, child_index| {
                if (source.children[child_index] != .empty) child.* = .source;
            }
            self.occurrence(id).kind = .{ .branch = branch };
        }

        fn appendIndexSource(
            self: *Self,
            source: IndexSource,
            parent: Parent,
        ) AllocUpdateError!OccurrenceId {
            return self.newOccurrence(
                .{ .source = source },
                parent,
                try encode.fromCodec(source.reference),
                false,
            );
        }

        fn appendCatalogDeferred(
            self: *Self,
            link: Catalog.Link,
            reference: node_codec.Reference,
            parent: Parent,
        ) AllocUpdateError!OccurrenceId {
            return switch (link) {
                .empty => error.InvalidNodeReference,
                .@"opaque" => switch (reference) {
                    .hashed => |digest| self.newOccurrence(
                        .{ .sealed = digest.* },
                        parent,
                        .{ .hashed = digest.* },
                        false,
                    ),
                    else => error.InvalidNodeReference,
                },
                else => if (link.node()) |source| self.newOccurrence(
                    .{ .source = source },
                    parent,
                    try encode.fromCodec(reference),
                    false,
                ) else error.InvalidNodeReference,
            };
        }

        fn childOccurrence(
            self: *Self,
            parent: OccurrenceId,
            child_index: usize,
        ) AllocUpdateError!?OccurrenceId {
            const branch = switch (self.occurrence(parent).kind) {
                .branch => |*value| value,
                else => unreachable,
            };
            return switch (branch.children[child_index]) {
                .empty => null,
                .occurrence => |id| id,
                .source => occurrence: {
                    if (comptime mode == .catalog) {
                        const child = try self.source_resolver.resolvedBranchChild(
                            branch.source orelse return error.InvalidNodeReference,
                            child_index,
                        );
                        const id = try self.appendCatalogDeferred(
                            child.link,
                            child.reference,
                            .{ .branch = .{ .node = parent, .child_index = @intCast(child_index) } },
                        );
                        self.occurrence(parent).kind.branch.children[child_index] = .{ .occurrence = id };
                        break :occurrence id;
                    }
                    const source = branch.source orelse return error.InvalidNodeReference;
                    const child = indexSource(source.children[child_index], false) orelse return error.InvalidNodeReference;
                    const id = try self.appendIndexSource(
                        child,
                        .{ .branch = .{ .node = parent, .child_index = @intCast(child_index) } },
                    );
                    self.occurrence(parent).kind.branch.children[child_index] = .{ .occurrence = id };
                    break :occurrence id;
                },
            };
        }

        fn markDirty(self: *Self, start: OccurrenceId) void {
            var current = start;
            while (true) {
                const node = self.occurrence(current);
                if (node.dirty) return;
                node.dirty = true;
                current = switch (node.parent) {
                    .root => return,
                    .extension => |parent| parent,
                    .branch => |parent| parent.node,
                };
            }
        }

        fn setParent(self: *Self, child: OccurrenceId, parent: Parent) void {
            self.occurrence(child).parent = parent;
        }

        fn insert(
            self: *Self,
            root: OccurrenceId,
            key: nibble.Path,
            value: []const u8,
        ) AllocUpdateError!void {
            var current = root;
            var remaining = key;
            while (true) {
                try self.materialize(current);
                const kind = self.occurrence(current).kind;
                switch (kind) {
                    .empty => {
                        self.occurrence(current).kind = .{ .leaf = .{ .path = remaining, .value = value } };
                        self.markDirty(current);
                        return;
                    },
                    .sealed, .source => unreachable,
                    .leaf => |leaf| {
                        if (leaf.path.len != remaining.len) return error.InvalidNode;
                        try self.insertIntoLeaf(current, leaf, remaining, value);
                        return;
                    },
                    .extension => |extension| {
                        if (extension.path.len >= remaining.len) return error.InvalidNode;
                        const common = extension.path.commonPrefix(remaining);
                        if (common != extension.path.len) {
                            try self.splitExtension(current, extension, remaining, value, common);
                            return;
                        }
                        current = extension.child;
                        remaining = remaining.slice(common, remaining.len);
                    },
                    .branch => {
                        if (remaining.len == 0) return error.InvalidNode;
                        const child_index = remaining.nibbleAt(0);
                        const child = (try self.childOccurrence(current, child_index)) orelse child: {
                            const created = try self.newOccurrence(
                                .empty,
                                .{ .branch = .{ .node = current, .child_index = child_index } },
                                .empty,
                                false,
                            );
                            self.occurrence(current).kind.branch.children[child_index] = .{ .occurrence = created };
                            break :child created;
                        };
                        current = child;
                        remaining = remaining.slice(1, remaining.len);
                    },
                }
            }
        }

        fn insertIntoLeaf(
            self: *Self,
            node: OccurrenceId,
            leaf: Occurrence.Leaf,
            key: nibble.Path,
            value: []const u8,
        ) AllocUpdateError!void {
            const common = leaf.path.commonPrefix(key);
            if (common == leaf.path.len and common == key.len) {
                self.occurrence(node).kind = .{ .leaf = .{ .path = leaf.path, .value = value } };
                self.markDirty(node);
                return;
            }

            if (common == 0) {
                self.occurrence(node).kind = .{ .branch = .empty };
                try self.populateSplitBranch(node, leaf.path, leaf.value, key, value);
            } else {
                const branch = try self.newOccurrence(
                    .{ .branch = .empty },
                    .{ .extension = node },
                    .unset,
                    true,
                );
                self.occurrence(node).kind = .{ .extension = .{
                    .path = key.slice(0, common),
                    .child = branch,
                } };
                try self.populateSplitBranch(
                    branch,
                    leaf.path.slice(common, leaf.path.len),
                    leaf.value,
                    key.slice(common, key.len),
                    value,
                );
            }
            self.markDirty(node);
        }

        fn populateSplitBranch(
            self: *Self,
            branch_id: OccurrenceId,
            old_path: nibble.Path,
            old_value: []const u8,
            new_path: nibble.Path,
            new_value: []const u8,
        ) AllocUpdateError!void {
            if (old_path.len == 0 or new_path.len == 0) return error.InvalidNode;
            const old_leaf = try self.newLeaf(
                old_path.slice(1, old_path.len),
                old_value,
                .{ .branch = .{ .node = branch_id, .child_index = old_path.nibbleAt(0) } },
            );
            self.occurrence(branch_id).kind.branch.children[old_path.nibbleAt(0)] = .{ .occurrence = old_leaf };
            const new_leaf = try self.newLeaf(
                new_path.slice(1, new_path.len),
                new_value,
                .{ .branch = .{ .node = branch_id, .child_index = new_path.nibbleAt(0) } },
            );
            self.occurrence(branch_id).kind.branch.children[new_path.nibbleAt(0)] = .{ .occurrence = new_leaf };
            self.markDirty(branch_id);
        }

        fn newLeaf(
            self: *Self,
            path: nibble.Path,
            value: []const u8,
            parent: Parent,
        ) Allocator.Error!OccurrenceId {
            return self.newOccurrence(.{ .leaf = .{ .path = path, .value = value } }, parent, .unset, true);
        }

        fn splitExtension(
            self: *Self,
            node: OccurrenceId,
            extension: Occurrence.Extension,
            key: nibble.Path,
            value: []const u8,
            common: usize,
        ) AllocUpdateError!void {
            const branch_id = if (common == 0) node else try self.newOccurrence(
                .{ .branch = .empty },
                .{ .extension = node },
                .unset,
                true,
            );
            if (common == 0) self.occurrence(node).kind = .{ .branch = .empty };

            const old_remaining = extension.path.slice(common, extension.path.len);
            const old_child = if (old_remaining.len == 1) extension.child else child: {
                const child = try self.newOccurrence(
                    .{ .extension = .{ .path = old_remaining.slice(1, old_remaining.len), .child = extension.child } },
                    .{ .branch = .{ .node = branch_id, .child_index = old_remaining.nibbleAt(0) } },
                    .unset,
                    true,
                );
                self.setParent(extension.child, .{ .extension = child });
                break :child child;
            };
            self.setParent(old_child, .{ .branch = .{ .node = branch_id, .child_index = old_remaining.nibbleAt(0) } });
            self.occurrence(branch_id).kind.branch.children[old_remaining.nibbleAt(0)] = .{ .occurrence = old_child };

            const new_remaining = key.slice(common, key.len);
            if (new_remaining.len == 0) return error.InvalidNode;
            const leaf = try self.newLeaf(
                new_remaining.slice(1, new_remaining.len),
                value,
                .{ .branch = .{ .node = branch_id, .child_index = new_remaining.nibbleAt(0) } },
            );
            self.occurrence(branch_id).kind.branch.children[new_remaining.nibbleAt(0)] = .{ .occurrence = leaf };

            if (common != 0) {
                self.occurrence(node).kind = .{ .extension = .{
                    .path = key.slice(0, common),
                    .child = branch_id,
                } };
            }
            self.markDirty(node);
        }

        fn delete(self: *Self, root: OccurrenceId, key: nibble.Path) AllocUpdateError!void {
            var current = root;
            var remaining = key;
            var frames: [max_path_nodes]DeleteFrame = undefined;
            var frame_count: u7 = 0;

            while (true) {
                try self.materialize(current);
                const kind = self.occurrence(current).kind;
                switch (kind) {
                    .empty => return,
                    .sealed, .source => unreachable,
                    .leaf => |leaf| {
                        if (leaf.path.len != remaining.len) return error.InvalidNode;
                        if (!leaf.path.eql(remaining)) return;
                        self.occurrence(current).kind = .empty;
                        self.occurrence(current).reference = .empty;
                        self.markDirty(current);
                        break;
                    },
                    .extension => |extension| {
                        if (extension.path.len >= remaining.len) return error.InvalidNode;
                        if (!remaining.startsWith(extension.path)) return;
                        std.debug.assert(frame_count < frames.len);
                        frames[frame_count] = .{ .extension = current };
                        frame_count += 1;
                        current = extension.child;
                        remaining = remaining.slice(extension.path.len, remaining.len);
                    },
                    .branch => {
                        if (remaining.len == 0) return error.InvalidNode;
                        const child_index = remaining.nibbleAt(0);
                        const child = (try self.childOccurrence(current, child_index)) orelse return;
                        std.debug.assert(frame_count < frames.len);
                        frames[frame_count] = .{ .branch = .{
                            .node = current,
                            .child_index = child_index,
                        } };
                        frame_count += 1;
                        current = child;
                        remaining = remaining.slice(1, remaining.len);
                    },
                }
            }

            while (frame_count != 0) {
                frame_count -= 1;
                switch (frames[frame_count]) {
                    .extension => |parent| try self.compressExtension(parent),
                    .branch => |parent| {
                        const child = switch (self.occurrence(parent.node).kind.branch.children[parent.child_index]) {
                            .occurrence => |id| id,
                            else => unreachable,
                        };
                        if (self.occurrence(child).kind == .empty) {
                            self.occurrence(parent.node).kind.branch.children[parent.child_index] = .empty;
                        }
                        try self.compressBranch(parent.node);
                    },
                }
            }
        }

        fn compressExtension(self: *Self, node: OccurrenceId) AllocUpdateError!void {
            const extension = switch (self.occurrence(node).kind) {
                .extension => |value| value,
                else => unreachable,
            };
            try self.materialize(extension.child);
            switch (self.occurrence(extension.child).kind) {
                .empty => self.occurrence(node).kind = .empty,
                .sealed, .source => unreachable,
                .branch => {
                    self.setParent(extension.child, .{ .extension = node });
                },
                .leaf => |leaf| {
                    self.occurrence(node).kind = .{ .leaf = .{
                        .path = try self.concat(extension.path, leaf.path),
                        .value = leaf.value,
                    } };
                },
                .extension => |child_extension| {
                    self.occurrence(node).kind = .{ .extension = .{
                        .path = try self.concat(extension.path, child_extension.path),
                        .child = child_extension.child,
                    } };
                    self.setParent(child_extension.child, .{ .extension = node });
                },
            }
            self.markDirty(node);
        }

        fn compressBranch(self: *Self, node: OccurrenceId) AllocUpdateError!void {
            const branch = switch (self.occurrence(node).kind) {
                .branch => |*value| value,
                else => unreachable,
            };
            var child_count: usize = 0;
            var only_child_index: usize = 0;
            for (&branch.children, 0..) |*child, index| {
                if (child.* == .empty) continue;
                child_count += 1;
                only_child_index = index;
            }

            if (child_count == 0) {
                self.occurrence(node).kind = .empty;
                self.occurrence(node).reference = .empty;
                self.markDirty(node);
                return;
            }
            if (child_count > 1) {
                self.markDirty(node);
                return;
            }

            const child = (try self.childOccurrence(node, only_child_index)) orelse unreachable;
            try self.materialize(child);
            const child_nibble: u8 = @intCast(only_child_index);
            switch (self.occurrence(child).kind) {
                .empty => self.occurrence(node).kind = .empty,
                .sealed, .source => unreachable,
                .branch => {
                    self.occurrence(node).kind = .{ .extension = .{
                        .path = try self.oneNibble(child_nibble),
                        .child = child,
                    } };
                    self.setParent(child, .{ .extension = node });
                },
                .leaf => |leaf| {
                    self.occurrence(node).kind = .{ .leaf = .{
                        .path = try self.prepend(child_nibble, leaf.path),
                        .value = leaf.value,
                    } };
                },
                .extension => |extension| {
                    self.occurrence(node).kind = .{ .extension = .{
                        .path = try self.prepend(child_nibble, extension.path),
                        .child = extension.child,
                    } };
                    self.setParent(extension.child, .{ .extension = node });
                },
            }
            self.markDirty(node);
        }

        fn encodeRoot(self: *Self, root: OccurrenceId) AllocUpdateError!hash.Root {
            var frames: std.ArrayList(EncodeFrame) = .empty;
            defer frames.deinit(self.allocator);
            try frames.append(self.allocator, .{ .node = root, .expanded = false, .is_root = true });
            var result: ?hash.Root = null;

            while (frames.pop()) |frame| {
                const node = self.occurrence(frame.node);
                if (!frame.expanded) switch (node.kind) {
                    .empty => {
                        if (!frame.is_root) return error.InvalidNode;
                        result = hash.empty_root;
                        continue;
                    },
                    .sealed, .source => return error.InvalidNode,
                    .leaf => |leaf| {
                        const lengths = try encode.leafPathBufferLengths(leaf.path.len, leaf.value);
                        const scratch = try self.buffers(lengths.compact, lengths.node);
                        const encoded = try encode.leafPath(scratch.node, scratch.compact, leaf.path, leaf.value);
                        try self.finishEncoding(frame.node, encoded, frame.is_root, &result);
                        continue;
                    },
                    .extension => |extension| {
                        try frames.append(self.allocator, .{
                            .node = frame.node,
                            .expanded = true,
                            .is_root = frame.is_root,
                        });
                        if (self.occurrence(extension.child).dirty) {
                            try frames.append(self.allocator, .{
                                .node = extension.child,
                                .expanded = false,
                                .is_root = false,
                            });
                        }
                        continue;
                    },
                    .branch => |*branch| {
                        try frames.append(self.allocator, .{
                            .node = frame.node,
                            .expanded = true,
                            .is_root = frame.is_root,
                        });
                        var index: usize = branch.children.len;
                        while (index > 0) {
                            index -= 1;
                            switch (branch.children[index]) {
                                .occurrence => |child| if (self.occurrence(child).dirty) {
                                    try frames.append(self.allocator, .{
                                        .node = child,
                                        .expanded = false,
                                        .is_root = false,
                                    });
                                },
                                .empty, .source => {},
                            }
                        }
                        continue;
                    },
                };

                const encoded = switch (node.kind) {
                    .extension => |extension| encoded: {
                        const reference = &self.occurrence(extension.child).reference;
                        const lengths = try encode.extensionPathBufferLengths(extension.path.len, reference);
                        const scratch = try self.buffers(lengths.compact, lengths.node);
                        break :encoded try encode.extensionPath(
                            scratch.node,
                            scratch.compact,
                            extension.path,
                            reference,
                        );
                    },
                    .branch => |*branch| encoded: {
                        const lengths = try self.branchBufferLengths(branch);
                        const scratch = try self.buffers(0, lengths.node);
                        break :encoded try self.encodeBranch(scratch.node, branch, lengths.payload);
                    },
                    else => unreachable,
                };
                try self.finishEncoding(frame.node, encoded, frame.is_root, &result);
            }
            return result orelse error.InvalidNode;
        }

        fn finishEncoding(
            self: *Self,
            node: OccurrenceId,
            encoded: []const u8,
            is_root: bool,
            result: *?hash.Root,
        ) AllocUpdateError!void {
            if (is_root) {
                const digest = self.keccak_context.keccak256(encoded);
                if (comptime Updates != void) try self.node_updates.append(digest, encoded);
                result.* = digest;
            } else if (encoded.len < 32) {
                var embedded: Reference.Embedded = .{
                    .len = @intCast(encoded.len),
                    .bytes = undefined,
                };
                @memcpy(embedded.bytes[0..encoded.len], encoded);
                self.occurrence(node).reference = .{ .embedded = embedded };
            } else {
                const digest = self.keccak_context.keccak256(encoded);
                if (comptime Updates != void) try self.node_updates.append(digest, encoded);
                self.occurrence(node).reference = .{ .hashed = digest };
            }
        }

        fn branchBufferLengths(self: *Self, branch: *const Occurrence.Branch) AllocUpdateError!BranchBufferLengths {
            if (comptime mode == .catalog) {
                const catalog_lengths = if (branch.source) |source|
                    try self.source_resolver.resolvedBranchReferenceEncodedLengths(source)
                else
                    null;
                var payload: usize = 1;
                for (&branch.children, 0..) |*child, index| {
                    const child_len = switch (child.*) {
                        .empty => 1,
                        .source => (catalog_lengths orelse return error.InvalidNodeReference)[index],
                        .occurrence => |child_id| try encode.referenceEncodedLen(&self.occurrence(child_id).reference),
                    };
                    payload = std.math.add(usize, payload, child_len) catch
                        return error.ResourceLimitExceeded;
                }
                return .{ .payload = payload, .node = try encode.listEncodedLen(payload) };
            }
            const source_lengths = if (branch.source) |source| lengths: {
                var lengths: [16]u8 = undefined;
                for (source.children, &lengths) |reference, *len| len.* = switch (reference) {
                    .empty => 1,
                    .embedded => |encoded| @intCast(encoded.len),
                    .hashed => 33,
                };
                break :lengths lengths;
            } else null;
            var payload: usize = 1;
            for (&branch.children, 0..) |*child, index| {
                const child_len = switch (child.*) {
                    .empty => 1,
                    .source => (source_lengths orelse return error.InvalidNodeReference)[index],
                    .occurrence => |id| try encode.referenceEncodedLen(&self.occurrence(id).reference),
                };
                payload = std.math.add(usize, payload, child_len) catch
                    return error.ResourceLimitExceeded;
            }
            return .{ .payload = payload, .node = try encode.listEncodedLen(payload) };
        }

        fn encodeBranch(
            self: *Self,
            node_buffer: []u8,
            branch: *const Occurrence.Branch,
            payload_len: usize,
        ) AllocUpdateError![]const u8 {
            var writer = try encode.listWriter(node_buffer, payload_len);
            if (comptime mode == .catalog) {
                for (&branch.children, 0..) |*child, index| switch (child.*) {
                    .empty => try encode.writeBytes(&writer, ""),
                    .source => try encode.writeCodecReference(
                        &writer,
                        try self.source_resolver.resolvedBranchReference(
                            branch.source orelse return error.InvalidNodeReference,
                            index,
                        ),
                    ),
                    .occurrence => |child_id| try encode.writeReference(
                        &writer,
                        &self.occurrence(child_id).reference,
                    ),
                };
                try encode.writeBytes(&writer, "");
                return node_buffer[0 .. encode.listPrefixLen(payload_len) + writer.written().len];
            }
            for (&branch.children, 0..) |*child, index| switch (child.*) {
                .empty => try encode.writeBytes(&writer, ""),
                .source => try encode.writeCodecReference(
                    &writer,
                    (branch.source orelse return error.InvalidNodeReference).children[index],
                ),
                .occurrence => |id| try encode.writeReference(&writer, &self.occurrence(id).reference),
            };
            try encode.writeBytes(&writer, "");
            return node_buffer[0 .. encode.listPrefixLen(payload_len) + writer.written().len];
        }

        fn concat(self: *Self, lhs: nibble.Path, rhs: nibble.Path) AllocUpdateError!nibble.Path {
            const len = std.math.add(usize, lhs.len, rhs.len) catch return error.ResourceLimitExceeded;
            const out = try self.alloc(u8, packedByteLen(len));
            writePacked(out, 0, lhs);
            writePacked(out, lhs.len, rhs);
            return .{ .key = out, .start = 0, .len = len };
        }

        fn prepend(self: *Self, first: u8, tail: nibble.Path) AllocUpdateError!nibble.Path {
            const len = std.math.add(usize, 1, tail.len) catch return error.ResourceLimitExceeded;
            const out = try self.alloc(u8, packedByteLen(len));
            @memset(out, 0);
            writePackedNibble(out, 0, first);
            writePacked(out, 1, tail);
            return .{ .key = out, .start = 0, .len = len };
        }

        fn oneNibble(self: *Self, value: u8) Allocator.Error!nibble.Path {
            const out = try self.alloc(u8, 1);
            out[0] = value << 4;
            return .{ .key = out, .start = 0, .len = 1 };
        }
    };
}

pub fn updateCatalogSorted(
    keccak_context: anytype,
    scratch_arena: *ScopedArenaAllocator,
    topology: *const Catalog,
    root_ref: Catalog.Root,
    updates: []const Update,
) AllocUpdateError!hash.Root {
    return updateCatalogSortedWithUpdates(
        keccak_context,
        scratch_arena,
        topology,
        root_ref,
        updates,
        {},
    );
}

pub fn updateCatalogSortedWithUpdates(
    keccak_context: anytype,
    scratch_arena: *ScopedArenaAllocator,
    topology: *const Catalog,
    root_ref: Catalog.Root,
    updates: []const Update,
    node_updates: anytype,
) AllocUpdateError!hash.Root {
    const root_hash = root_ref.digest();
    if (updates.len == 0) return root_hash;
    try validateUpdates(updates);

    const mark = scratch_arena.mark();
    defer scratch_arena.rewind(mark);
    return updateResolved(
        .catalog,
        keccak_context,
        scratch_arena.allocator(),
        topology,
        switch (root_ref) {
            .empty => null,
            .node => |authenticated| authenticated.id,
        },
        root_hash,
        updates,
        node_updates,
    );
}

pub fn updateIndexSorted(
    keccak_context: anytype,
    scratch_arena: *ScopedArenaAllocator,
    root_hash: hash.Root,
    index: *const proof.NodeIndex,
    updates: []const Update,
) AllocUpdateError!hash.Root {
    return updateIndexSortedWithUpdates(
        keccak_context,
        scratch_arena,
        root_hash,
        index,
        updates,
        {},
    );
}

pub fn updateIndexSortedWithUpdates(
    keccak_context: anytype,
    scratch_arena: *ScopedArenaAllocator,
    root_hash: hash.Root,
    index: *const proof.NodeIndex,
    updates: []const Update,
    node_updates: anytype,
) AllocUpdateError!hash.Root {
    if (updates.len == 0) return root_hash;
    try validateUpdates(updates);

    const mark = scratch_arena.mark();
    defer scratch_arena.rewind(mark);
    return updateResolved(
        .index,
        keccak_context,
        scratch_arena.allocator(),
        index,
        if (std.mem.eql(u8, &root_hash, &hash.empty_root)) null else .{
            .reference = .{ .hashed = &root_hash },
            .require_branch = false,
            .root = true,
        },
        root_hash,
        updates,
        node_updates,
    );
}

fn updateResolved(
    comptime mode: SourceMode,
    keccak_context: anytype,
    allocator: Allocator,
    source_resolver: if (mode == .catalog) *const Catalog else *const proof.NodeIndex,
    root_source: ?Source(mode),
    root_hash: hash.Root,
    updates: []const Update,
    node_updates: anytype,
) AllocUpdateError!hash.Root {
    var context: Context(@TypeOf(keccak_context), mode, @TypeOf(node_updates)) = .{
        .allocator = allocator,
        .keccak_context = keccak_context,
        .source_resolver = source_resolver,
        .node_updates = node_updates,
    };
    defer context.deinit();
    const root = if (root_source) |source|
        try context.newOccurrence(
            .{ .source = source },
            .root,
            .unset,
            false,
        )
    else
        try context.newOccurrence(.empty, .root, .empty, false);

    for (updates) |*update| {
        const value = update.value orelse continue;
        const path: nibble.Path = .{ .key = &update.key, .start = 0, .len = key_nibbles };
        try context.insert(root, path, value);
    }
    for (updates) |*update| {
        if (update.value != null) continue;
        const path: nibble.Path = .{ .key = &update.key, .start = 0, .len = key_nibbles };
        try context.delete(root, path);
    }

    if (!context.occurrence(root).dirty) return root_hash;
    return context.encodeRoot(root);
}

fn compactPath(path: nibble.CompactPath) nibble.Path {
    return .{ .key = path.encoded, .start = path.nibble_offset, .len = path.len };
}

fn packedByteLen(nibble_len: usize) usize {
    return (nibble_len + 1) / 2;
}

fn writePacked(out: []u8, start: usize, path: nibble.Path) void {
    for (0..path.len) |index| writePackedNibble(out, start + index, path.nibbleAt(index));
}

fn writePackedNibble(out: []u8, index: usize, value: u8) void {
    std.debug.assert(value < 16);
    const byte = &out[index / 2];
    if (index % 2 == 0) {
        byte.* = value << 4;
    } else {
        byte.* |= value;
    }
}

fn validateUpdates(updates: []const Update) errors.InputError!void {
    for (updates) |update| {
        if (update.value) |value| {
            if (value.len == 0) return error.EmptyValue;
        }
    }
    for (updates[1..], 1..) |update, index| {
        switch (std.mem.order(u8, &updates[index - 1].key, &update.key)) {
            .lt => {},
            .eq => return error.DuplicateKey,
            .gt => return error.UnsortedKeys,
        }
    }
}

const BranchBufferLengths = struct {
    payload: usize,
    node: usize,
};
