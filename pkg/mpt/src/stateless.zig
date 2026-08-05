//! Block-local mutation and commit over an authenticated witness catalog.
//!
//! The catalog is the immutable commitment topology. This module creates
//! mutable occurrences only for selected paths, keeps untouched children as
//! authenticated references, and recomputes one post-state root bottom-up.

const std = @import("std");
const rlp = @import("rlp");

const catalog = @import("catalog.zig");
const errors = @import("error.zig");
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");
const node_codec = @import("node.zig");

const Allocator = std.mem.Allocator;
const UpdateError = errors.UpdateError;
const AllocUpdateError = Allocator.Error || UpdateError;

pub const Update = struct {
    key: hash.Root,
    value: ?[]const u8,
};

pub const Workspace = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) Workspace {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Workspace) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn reset(self: *Workspace) Allocator {
        _ = self.arena.reset(.retain_capacity);
        return self.arena.allocator();
    }
};

const OccurrenceId = enum(u32) { _ };

const Reference = union(enum) {
    unset,
    empty,
    embedded: Embedded,
    hashed: hash.Root,

    const Embedded = struct {
        len: u8,
        bytes: [31]u8,
    };

    comptime {
        // This value is stored in every mutable occurrence. Padding it to
        // eight-byte alignment costs more than aligned digest loads save.
        std.debug.assert(@sizeOf(Reference) == 33);
        std.debug.assert(@alignOf(Reference) == 1);
    }
};

const Parent = union(enum) {
    root,
    extension: OccurrenceId,
    branch: struct {
        node: OccurrenceId,
        child_index: u8,
    },
};

const Occurrence = struct {
    kind: Kind,
    parent: Parent,
    reference: Reference = .unset,
    dirty: bool = false,

    const Kind = union(enum) {
        empty,
        sealed: hash.Root,
        source: catalog.NodeId,
        leaf: Leaf,
        extension: Extension,
        branch: Branch,
    };

    const Leaf = struct {
        path: []const u8,
        value: []const u8,
    };

    const Extension = struct {
        path: []const u8,
        child: OccurrenceId,
    };

    const Branch = struct {
        source: ?catalog.NodeId,
        children: [16]Child,
        value: ?[]const u8,

        pub const empty = Branch{
            .source = null,
            .children = [_]Child{.empty} ** 16,
            .value = null,
        };
    };

    const Child = union(enum) {
        empty,
        catalog,
        // The union already occupies eight bytes. Align its only payload so
        // branch child arrays can use natural RV64 word loads without growing.
        occurrence: OccurrenceId align(8),

        comptime {
            std.debug.assert(@sizeOf(Child) == 8);
            std.debug.assert(@alignOf(Child) == 8);
        }
    };
};

comptime {
    std.debug.assert(@sizeOf(Occurrence.Kind) == 160);
    std.debug.assert(@alignOf(Occurrence.Kind) == 8);
    std.debug.assert(@sizeOf(Occurrence) == 208);
    std.debug.assert(@alignOf(Occurrence) == 8);
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

fn Context(comptime KeccakContext: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        keccak_context: KeccakContext,
        catalog: *const catalog.Catalog,
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
            const id: OccurrenceId = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
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
    };
}

pub fn updateSorted(
    keccak_context: anytype,
    workspace: *Workspace,
    root_hash: hash.Root,
    topology: *const catalog.Catalog,
    root_ref: catalog.RootRef,
    updates: []const Update,
) AllocUpdateError!hash.Root {
    try validateRoot(root_hash, root_ref);
    if (updates.len == 0) return root_hash;
    try validateUpdates(updates);

    const allocator = workspace.reset();
    var context: Context(@TypeOf(keccak_context)) = .{
        .allocator = allocator,
        .keccak_context = keccak_context,
        .catalog = topology,
    };
    defer context.deinit();
    const root = switch (root_ref) {
        .empty => try context.newOccurrence(.empty, .root, .empty, false),
        .node => |authenticated| try context.newOccurrence(
            .{ .source = authenticated.id },
            .root,
            .unset,
            false,
        ),
    };

    for (updates) |update| {
        const value = update.value orelse continue;
        const path = try keyNibbles(&context, update.key);
        try insert(&context, root, path, value);
    }
    for (updates) |update| {
        if (update.value != null) continue;
        const path = try keyNibbles(&context, update.key);
        try delete(&context, root, path);
    }

    if (!context.occurrence(root).dirty) return root_hash;
    return encodeRoot(&context, root);
}

fn validateRoot(root_hash: hash.Root, root_ref: catalog.RootRef) UpdateError!void {
    switch (root_ref) {
        .empty => if (!std.mem.eql(u8, &root_hash, &hash.empty_root)) {
            return error.InvalidNodeReference;
        },
        .node => |root| if (!std.mem.eql(u8, &root_hash, &root.digest)) {
            return error.InvalidNodeReference;
        },
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

fn materialize(context: anytype, id: OccurrenceId) AllocUpdateError!void {
    const source_id = switch (context.occurrence(id).kind) {
        .source => |source| source,
        .sealed => return error.MissingNode,
        else => return,
    };
    const entry = context.catalog.node(source_id) orelse return error.InvalidNodeReference;
    switch (entry.kind) {
        .leaf => {
            const path = entry.path() orelse return error.InvalidNode;
            context.occurrence(id).kind = .{ .leaf = .{
                .path = try copyCompactPath(context, path),
                .value = entry.value() orelse return error.InvalidNode,
            } };
        },
        .extension => {
            const path = entry.path() orelse return error.InvalidNode;
            const link = entry.extensionChild() orelse return error.InvalidNodeReference;
            const reference = try context.catalog.extensionReference(source_id);
            const child = try appendDeferred(
                context,
                link,
                reference,
                .{ .extension = id },
            );
            context.occurrence(id).kind = .{ .extension = .{
                .path = try copyCompactPath(context, path),
                .child = child,
            } };
        },
        .branch => {
            const links = context.catalog.branchChildren(source_id) orelse
                return error.InvalidNodeReference;
            var branch = Occurrence.Branch.empty;
            branch.source = source_id;
            for (links, 0..) |link, child_index| {
                if (link == .empty) continue;
                branch.children[child_index] = .catalog;
            }
            branch.value = entry.value();
            context.occurrence(id).kind = .{ .branch = branch };
        },
    }
}

fn appendDeferred(
    context: anytype,
    link: catalog.Link,
    reference: node_codec.Reference,
    parent: Parent,
) AllocUpdateError!OccurrenceId {
    return switch (link) {
        .empty => error.InvalidNodeReference,
        .@"opaque" => switch (reference) {
            .hashed => |digest| context.newOccurrence(
                .{ .sealed = digest.* },
                parent,
                .{ .hashed = digest.* },
                false,
            ),
            else => error.InvalidNodeReference,
        },
        else => if (link.node()) |id| context.newOccurrence(
            .{ .source = id },
            parent,
            try referenceFromCodec(reference),
            false,
        ) else error.InvalidNodeReference,
    };
}

fn childOccurrence(
    context: anytype,
    parent: OccurrenceId,
    child_index: usize,
) AllocUpdateError!?OccurrenceId {
    const branch = switch (context.occurrence(parent).kind) {
        .branch => |*value| value,
        else => unreachable,
    };
    return switch (branch.children[child_index]) {
        .empty => null,
        .occurrence => |id| id,
        .catalog => occurrence: {
            const source = branch.source orelse return error.InvalidNodeReference;
            const links = context.catalog.branchChildren(source) orelse
                return error.InvalidNodeReference;
            const reference = try context.catalog.branchReference(source, child_index);
            const id = try appendDeferred(
                context,
                links[child_index],
                reference,
                .{ .branch = .{ .node = parent, .child_index = @intCast(child_index) } },
            );
            context.occurrence(parent).kind.branch.children[child_index] = .{ .occurrence = id };
            break :occurrence id;
        },
    };
}

fn markDirty(context: anytype, start: OccurrenceId) void {
    var current = start;
    while (true) {
        const node = context.occurrence(current);
        if (node.dirty) return;
        node.dirty = true;
        current = switch (node.parent) {
            .root => return,
            .extension => |parent| parent,
            .branch => |parent| parent.node,
        };
    }
}

fn setParent(context: anytype, child: OccurrenceId, parent: Parent) void {
    context.occurrence(child).parent = parent;
}

fn copyCompactPath(context: anytype, path: nibble.CompactPath) AllocUpdateError![]u8 {
    const owned = try context.alloc(u8, path.len);
    for (owned, 0..) |*path_nibble, index| path_nibble.* = path.nibbleAt(index);
    return owned;
}

fn insert(
    context: anytype,
    root: OccurrenceId,
    key: []const u8,
    value: []const u8,
) AllocUpdateError!void {
    var current = root;
    var remaining = key;
    while (true) {
        try materialize(context, current);
        const kind = context.occurrence(current).kind;
        switch (kind) {
            .empty => {
                context.occurrence(current).kind = .{ .leaf = .{ .path = remaining, .value = value } };
                markDirty(context, current);
                return;
            },
            .sealed, .source => unreachable,
            .leaf => |leaf| {
                try insertIntoLeaf(context, current, leaf, remaining, value);
                return;
            },
            .extension => |extension| {
                const common = commonPrefix(extension.path, remaining);
                if (common != extension.path.len) {
                    try splitExtension(context, current, extension, remaining, value, common);
                    return;
                }
                current = extension.child;
                remaining = remaining[common..];
            },
            .branch => |branch| {
                if (remaining.len == 0) {
                    context.occurrence(current).kind.branch.value = value;
                    markDirty(context, current);
                    return;
                }
                const child_index = remaining[0];
                const child = (try childOccurrence(context, current, child_index)) orelse child: {
                    const created = try context.newOccurrence(
                        .empty,
                        .{ .branch = .{ .node = current, .child_index = child_index } },
                        .empty,
                        false,
                    );
                    context.occurrence(current).kind.branch.children[child_index] = .{ .occurrence = created };
                    break :child created;
                };
                _ = branch;
                current = child;
                remaining = remaining[1..];
            },
        }
    }
}

fn insertIntoLeaf(
    context: anytype,
    node: OccurrenceId,
    leaf: Occurrence.Leaf,
    key: []const u8,
    value: []const u8,
) AllocUpdateError!void {
    const common = commonPrefix(leaf.path, key);
    if (common == leaf.path.len and common == key.len) {
        context.occurrence(node).kind = .{ .leaf = .{ .path = leaf.path, .value = value } };
        markDirty(context, node);
        return;
    }

    if (common == 0) {
        context.occurrence(node).kind = .{ .branch = .empty };
        try populateSplitBranch(context, node, leaf.path, leaf.value, key, value);
    } else {
        const branch = try context.newOccurrence(
            .{ .branch = .empty },
            .{ .extension = node },
            .unset,
            true,
        );
        context.occurrence(node).kind = .{ .extension = .{
            .path = key[0..common],
            .child = branch,
        } };
        try populateSplitBranch(context, branch, leaf.path[common..], leaf.value, key[common..], value);
    }
    markDirty(context, node);
}

fn populateSplitBranch(
    context: anytype,
    branch_id: OccurrenceId,
    old_path: []const u8,
    old_value: []const u8,
    new_path: []const u8,
    new_value: []const u8,
) AllocUpdateError!void {
    if (old_path.len == 0) {
        context.occurrence(branch_id).kind.branch.value = old_value;
    } else {
        const leaf = try newLeaf(
            context,
            old_path[1..],
            old_value,
            .{ .branch = .{ .node = branch_id, .child_index = old_path[0] } },
        );
        context.occurrence(branch_id).kind.branch.children[old_path[0]] = .{ .occurrence = leaf };
    }
    if (new_path.len == 0) {
        context.occurrence(branch_id).kind.branch.value = new_value;
    } else {
        const leaf = try newLeaf(
            context,
            new_path[1..],
            new_value,
            .{ .branch = .{ .node = branch_id, .child_index = new_path[0] } },
        );
        context.occurrence(branch_id).kind.branch.children[new_path[0]] = .{ .occurrence = leaf };
    }
    markDirty(context, branch_id);
}

fn newLeaf(
    context: anytype,
    path: []const u8,
    value: []const u8,
    parent: Parent,
) Allocator.Error!OccurrenceId {
    return context.newOccurrence(.{ .leaf = .{ .path = path, .value = value } }, parent, .unset, true);
}

fn splitExtension(
    context: anytype,
    node: OccurrenceId,
    extension: Occurrence.Extension,
    key: []const u8,
    value: []const u8,
    common: usize,
) AllocUpdateError!void {
    const branch_id = if (common == 0) node else try context.newOccurrence(
        .{ .branch = .empty },
        .{ .extension = node },
        .unset,
        true,
    );
    if (common == 0) context.occurrence(node).kind = .{ .branch = .empty };

    const old_remaining = extension.path[common..];
    const old_child = if (old_remaining.len == 1) extension.child else child: {
        const child = try context.newOccurrence(
            .{ .extension = .{ .path = old_remaining[1..], .child = extension.child } },
            .{ .branch = .{ .node = branch_id, .child_index = old_remaining[0] } },
            .unset,
            true,
        );
        setParent(context, extension.child, .{ .extension = child });
        break :child child;
    };
    setParent(context, old_child, .{ .branch = .{ .node = branch_id, .child_index = old_remaining[0] } });
    context.occurrence(branch_id).kind.branch.children[old_remaining[0]] = .{ .occurrence = old_child };

    const new_remaining = key[common..];
    if (new_remaining.len == 0) {
        context.occurrence(branch_id).kind.branch.value = value;
    } else {
        const leaf = try newLeaf(
            context,
            new_remaining[1..],
            value,
            .{ .branch = .{ .node = branch_id, .child_index = new_remaining[0] } },
        );
        context.occurrence(branch_id).kind.branch.children[new_remaining[0]] = .{ .occurrence = leaf };
    }

    if (common != 0) {
        context.occurrence(node).kind = .{ .extension = .{
            .path = key[0..common],
            .child = branch_id,
        } };
    }
    markDirty(context, node);
}

fn delete(context: anytype, root: OccurrenceId, key: []const u8) AllocUpdateError!void {
    var current = root;
    var remaining = key;
    var frames: std.ArrayList(DeleteFrame) = .empty;
    defer frames.deinit(context.allocator);

    while (true) {
        try materialize(context, current);
        const kind = context.occurrence(current).kind;
        switch (kind) {
            .empty => return,
            .sealed, .source => unreachable,
            .leaf => |leaf| {
                if (!std.mem.eql(u8, leaf.path, remaining)) return;
                context.occurrence(current).kind = .empty;
                context.occurrence(current).reference = .empty;
                markDirty(context, current);
                break;
            },
            .extension => |extension| {
                if (!startsWith(remaining, extension.path)) return;
                try frames.append(context.allocator, .{ .extension = current });
                current = extension.child;
                remaining = remaining[extension.path.len..];
            },
            .branch => |branch| {
                if (remaining.len == 0) {
                    if (branch.value == null) return;
                    context.occurrence(current).kind.branch.value = null;
                    markDirty(context, current);
                    try compressBranch(context, current);
                    break;
                }
                const child_index = remaining[0];
                const child = (try childOccurrence(context, current, child_index)) orelse return;
                try frames.append(context.allocator, .{ .branch = .{
                    .node = current,
                    .child_index = child_index,
                } });
                current = child;
                remaining = remaining[1..];
            },
        }
    }

    while (frames.pop()) |frame| switch (frame) {
        .extension => |parent| try compressExtension(context, parent),
        .branch => |parent| {
            const child = switch (context.occurrence(parent.node).kind.branch.children[parent.child_index]) {
                .occurrence => |id| id,
                else => unreachable,
            };
            if (context.occurrence(child).kind == .empty) {
                context.occurrence(parent.node).kind.branch.children[parent.child_index] = .empty;
            }
            try compressBranch(context, parent.node);
        },
    };
}

fn compressExtension(context: anytype, node: OccurrenceId) AllocUpdateError!void {
    const extension = switch (context.occurrence(node).kind) {
        .extension => |value| value,
        else => unreachable,
    };
    try materialize(context, extension.child);
    switch (context.occurrence(extension.child).kind) {
        .empty => context.occurrence(node).kind = .empty,
        .sealed, .source => unreachable,
        .branch => {
            setParent(context, extension.child, .{ .extension = node });
        },
        .leaf => |leaf| {
            context.occurrence(node).kind = .{ .leaf = .{
                .path = try concat(context, extension.path, leaf.path),
                .value = leaf.value,
            } };
        },
        .extension => |child_extension| {
            context.occurrence(node).kind = .{ .extension = .{
                .path = try concat(context, extension.path, child_extension.path),
                .child = child_extension.child,
            } };
            setParent(context, child_extension.child, .{ .extension = node });
        },
    }
    markDirty(context, node);
}

fn compressBranch(context: anytype, node: OccurrenceId) AllocUpdateError!void {
    const branch = switch (context.occurrence(node).kind) {
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

    if (branch.value) |value| {
        if (child_count == 0) {
            context.occurrence(node).kind = .{ .leaf = .{ .path = &.{}, .value = value } };
        }
        markDirty(context, node);
        return;
    }
    if (child_count == 0) {
        context.occurrence(node).kind = .empty;
        context.occurrence(node).reference = .empty;
        markDirty(context, node);
        return;
    }
    if (child_count > 1) {
        markDirty(context, node);
        return;
    }

    const child = (try childOccurrence(context, node, only_child_index)) orelse unreachable;
    try materialize(context, child);
    const child_nibble: u8 = @intCast(only_child_index);
    switch (context.occurrence(child).kind) {
        .empty => context.occurrence(node).kind = .empty,
        .sealed, .source => unreachable,
        .branch => {
            context.occurrence(node).kind = .{ .extension = .{
                .path = try oneNibble(context, child_nibble),
                .child = child,
            } };
            setParent(context, child, .{ .extension = node });
        },
        .leaf => |leaf| {
            context.occurrence(node).kind = .{ .leaf = .{
                .path = try prepend(context, child_nibble, leaf.path),
                .value = leaf.value,
            } };
        },
        .extension => |extension| {
            context.occurrence(node).kind = .{ .extension = .{
                .path = try prepend(context, child_nibble, extension.path),
                .child = extension.child,
            } };
            setParent(context, extension.child, .{ .extension = node });
        },
    }
    markDirty(context, node);
}

fn encodeRoot(context: anytype, root: OccurrenceId) AllocUpdateError!hash.Root {
    var frames: std.ArrayList(EncodeFrame) = .empty;
    defer frames.deinit(context.allocator);
    try frames.append(context.allocator, .{ .node = root, .expanded = false, .is_root = true });
    var result: ?hash.Root = null;

    while (frames.pop()) |frame| {
        const node = context.occurrence(frame.node);
        if (!frame.expanded) switch (node.kind) {
            .empty => {
                if (!frame.is_root) return error.InvalidNode;
                result = hash.empty_root;
                continue;
            },
            .sealed, .source => return error.InvalidNode,
            .leaf => |leaf| {
                const lengths = try leafBufferLengths(leaf.path, leaf.value);
                const buffers = try context.buffers(lengths.compact, lengths.node);
                const encoded = try encodeLeaf(buffers.node, buffers.compact, leaf.path, leaf.value);
                try finishEncoding(context, frame.node, encoded, frame.is_root, &result);
                continue;
            },
            .extension => |extension| {
                try frames.append(context.allocator, .{
                    .node = frame.node,
                    .expanded = true,
                    .is_root = frame.is_root,
                });
                if (context.occurrence(extension.child).dirty) {
                    try frames.append(context.allocator, .{
                        .node = extension.child,
                        .expanded = false,
                        .is_root = false,
                    });
                }
                continue;
            },
            .branch => |*branch| {
                try frames.append(context.allocator, .{
                    .node = frame.node,
                    .expanded = true,
                    .is_root = frame.is_root,
                });
                var index: usize = branch.children.len;
                while (index > 0) {
                    index -= 1;
                    switch (branch.children[index]) {
                        .occurrence => |child| if (context.occurrence(child).dirty) {
                            try frames.append(context.allocator, .{
                                .node = child,
                                .expanded = false,
                                .is_root = false,
                            });
                        },
                        .empty, .catalog => {},
                    }
                }
                continue;
            },
        };

        const encoded = switch (node.kind) {
            .extension => |extension| encoded: {
                const reference = &context.occurrence(extension.child).reference;
                const lengths = try extensionBufferLengths(extension.path, reference);
                const buffers = try context.buffers(lengths.compact, lengths.node);
                break :encoded try encodeExtension(
                    buffers.node,
                    buffers.compact,
                    extension.path,
                    reference,
                );
            },
            .branch => |*branch| encoded: {
                const lengths = try branchBufferLengths(context, branch);
                const buffers = try context.buffers(0, lengths.node);
                break :encoded try encodeBranch(context, buffers.node, branch, lengths.payload);
            },
            else => unreachable,
        };
        try finishEncoding(context, frame.node, encoded, frame.is_root, &result);
    }
    return result orelse error.InvalidNode;
}

fn finishEncoding(
    context: anytype,
    node: OccurrenceId,
    encoded: []const u8,
    is_root: bool,
    result: *?hash.Root,
) AllocUpdateError!void {
    if (is_root) {
        result.* = context.keccak_context.keccak256(encoded);
    } else if (encoded.len < 32) {
        var embedded: Reference.Embedded = .{
            .len = @intCast(encoded.len),
            .bytes = undefined,
        };
        @memcpy(embedded.bytes[0..encoded.len], encoded);
        context.occurrence(node).reference = .{ .embedded = embedded };
    } else {
        context.occurrence(node).reference = .{ .hashed = context.keccak_context.keccak256(encoded) };
    }
}

const BufferLengths = struct {
    compact: usize,
    node: usize,
};

fn leafBufferLengths(path: []const u8, value: []const u8) UpdateError!BufferLengths {
    const compact = try compactOutputLen(path);
    const payload = try addEncodedLengths(&.{
        try bytesEncodedLenUpperBound(compact),
        try bytesEncodedLen(value),
    });
    return .{ .compact = compact, .node = try listEncodedLen(payload) };
}

fn extensionBufferLengths(path: []const u8, child_reference: *const Reference) UpdateError!BufferLengths {
    const compact = try compactOutputLen(path);
    const payload = try addEncodedLengths(&.{
        try bytesEncodedLenUpperBound(compact),
        try referenceEncodedLen(child_reference),
    });
    return .{ .compact = compact, .node = try listEncodedLen(payload) };
}

const BranchBufferLengths = struct {
    payload: usize,
    node: usize,
};

fn branchBufferLengths(context: anytype, branch: *const Occurrence.Branch) UpdateError!BranchBufferLengths {
    var payload = try bytesEncodedLen(branch.value orelse "");
    for (&branch.children, 0..) |*child, index| {
        const child_len = switch (child.*) {
            .empty => 1,
            .catalog => try context.catalog.branchReferenceEncodedLen(
                branch.source orelse return error.InvalidNodeReference,
                index,
            ),
            .occurrence => |id| try referenceEncodedLen(&context.occurrence(id).reference),
        };
        payload = std.math.add(usize, payload, child_len) catch
            return error.ResourceLimitExceeded;
    }
    return .{ .payload = payload, .node = try listEncodedLen(payload) };
}

fn encodeLeaf(
    node_buffer: []u8,
    compact_buffer: []u8,
    path: []const u8,
    value: []const u8,
) UpdateError![]const u8 {
    const compact = try encodeCompact(compact_buffer, path, true);
    const payload_len = try addEncodedLengths(&.{
        try bytesEncodedLen(compact),
        try bytesEncodedLen(value),
    });
    var writer = try listWriter(node_buffer, payload_len);
    try writeBytes(&writer, compact);
    try writeBytes(&writer, value);
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

fn encodeExtension(
    node_buffer: []u8,
    compact_buffer: []u8,
    path: []const u8,
    child_reference: *const Reference,
) UpdateError![]const u8 {
    if (child_reference.* == .unset or child_reference.* == .empty) return error.InvalidNode;
    const compact = try encodeCompact(compact_buffer, path, false);
    const payload_len = try addEncodedLengths(&.{
        try bytesEncodedLen(compact),
        try referenceEncodedLen(child_reference),
    });
    var writer = try listWriter(node_buffer, payload_len);
    try writeBytes(&writer, compact);
    try writeReference(&writer, child_reference);
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

fn encodeBranch(
    context: anytype,
    node_buffer: []u8,
    branch: *const Occurrence.Branch,
    payload_len: usize,
) UpdateError![]const u8 {
    var writer = try listWriter(node_buffer, payload_len);
    for (&branch.children, 0..) |*child, index| switch (child.*) {
        .empty => try writeBytes(&writer, ""),
        .catalog => try writeCodecReference(
            &writer,
            try context.catalog.branchReference(
                branch.source orelse return error.InvalidNodeReference,
                index,
            ),
        ),
        .occurrence => |id| try writeReference(&writer, &context.occurrence(id).reference),
    };
    try writeBytes(&writer, branch.value orelse "");
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

fn encodeCompact(out: []u8, path: []const u8, terminal: bool) UpdateError![]const u8 {
    const out_len = std.math.add(usize, 1, path.len / 2) catch
        return error.ResourceLimitExceeded;
    if (out_len > out.len) return error.ResourceLimitExceeded;
    const odd = path.len % 2 == 1;
    const flags: u8 = (@as(u8, @intFromBool(terminal)) << 1) |
        @as(u8, @intFromBool(odd));
    out[0] = flags << 4;
    var path_index: usize = 0;
    var out_index: usize = 1;
    if (odd) {
        out[0] |= path[0];
        path_index = 1;
    }
    while (path_index < path.len) : ({
        path_index += 2;
        out_index += 1;
    }) {
        out[out_index] = (path[path_index] << 4) | path[path_index + 1];
    }
    return out[0..out_len];
}

fn listWriter(node_buffer: []u8, payload_len: usize) UpdateError!rlp.Writer {
    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    const prefix = rlp.listPrefix(&prefix_buffer, payload_len);
    const total_len = std.math.add(usize, prefix.len, payload_len) catch
        return error.ResourceLimitExceeded;
    if (total_len > node_buffer.len) return error.ResourceLimitExceeded;
    @memcpy(node_buffer[0..prefix.len], prefix);
    return rlp.Writer.fixed(node_buffer[prefix.len..total_len]);
}

fn writeBytes(writer: *rlp.Writer, value: []const u8) UpdateError!void {
    writer.bytes(value) catch |err| switch (err) {
        error.NoSpaceLeft => return error.ResourceLimitExceeded,
        error.OutOfMemory => unreachable,
    };
}

fn writeReference(writer: *rlp.Writer, reference: *const Reference) UpdateError!void {
    switch (reference.*) {
        .unset, .empty => return error.InvalidNode,
        .hashed => |*digest| try writeBytes(writer, digest),
        .embedded => |*embedded| {
            const item = try rlp.parseExact(embedded.bytes[0..embedded.len]);
            writer.raw(item) catch |err| switch (err) {
                error.NoSpaceLeft => return error.ResourceLimitExceeded,
                error.OutOfMemory => unreachable,
            };
        },
    }
}

fn writeCodecReference(writer: *rlp.Writer, reference: node_codec.Reference) UpdateError!void {
    switch (reference) {
        .empty => return error.InvalidNode,
        .hashed => |digest| try writeBytes(writer, digest),
        .embedded => |encoded| {
            const item = try rlp.parseExact(encoded);
            writer.raw(item) catch |err| switch (err) {
                error.NoSpaceLeft => return error.ResourceLimitExceeded,
                error.OutOfMemory => unreachable,
            };
        },
    }
}

fn referenceFromCodec(reference: node_codec.Reference) UpdateError!Reference {
    return switch (reference) {
        .empty => .empty,
        .hashed => |digest| .{ .hashed = digest.* },
        .embedded => |encoded| embedded: {
            if (encoded.len >= 32) return error.InvalidNodeReference;
            var value: Reference.Embedded = .{
                .len = @intCast(encoded.len),
                .bytes = undefined,
            };
            @memcpy(value.bytes[0..encoded.len], encoded);
            break :embedded .{ .embedded = value };
        },
    };
}

fn referenceEncodedLen(reference: *const Reference) UpdateError!usize {
    return switch (reference.*) {
        .unset, .empty => error.InvalidNode,
        .hashed => 33,
        .embedded => |*embedded| embedded.len,
    };
}

fn compactOutputLen(path: []const u8) UpdateError!usize {
    return std.math.add(usize, 1, path.len / 2) catch
        error.ResourceLimitExceeded;
}

fn bytesEncodedLenUpperBound(value_len: usize) UpdateError!usize {
    const prefix_len: usize = if (value_len < 56)
        1
    else
        std.math.add(usize, 1, lengthByteLen(value_len)) catch
            return error.ResourceLimitExceeded;
    return std.math.add(usize, prefix_len, value_len) catch
        error.ResourceLimitExceeded;
}

fn bytesEncodedLen(value: []const u8) UpdateError!usize {
    if (value.len == 1 and value[0] < 0x80) return 1;
    const prefix_len: usize = if (value.len < 56)
        1
    else
        std.math.add(usize, 1, lengthByteLen(value.len)) catch
            return error.ResourceLimitExceeded;
    return std.math.add(usize, prefix_len, value.len) catch
        error.ResourceLimitExceeded;
}

fn listEncodedLen(payload_len: usize) UpdateError!usize {
    return std.math.add(usize, listPrefixLen(payload_len), payload_len) catch
        error.ResourceLimitExceeded;
}

fn listPrefixLen(payload_len: usize) usize {
    return if (payload_len < 56) 1 else 1 + lengthByteLen(payload_len);
}

fn lengthByteLen(value: usize) usize {
    return (@bitSizeOf(usize) - @clz(value) + 7) / 8;
}

fn addEncodedLengths(lengths: []const usize) UpdateError!usize {
    var total: usize = 0;
    for (lengths) |len| {
        total = std.math.add(usize, total, len) catch
            return error.ResourceLimitExceeded;
    }
    return total;
}

fn keyNibbles(context: anytype, key: hash.Root) AllocUpdateError![]u8 {
    const out = try context.alloc(u8, 64);
    for (out, 0..) |*value, index| value.* = nibble.keyNibbleAt(&key, index);
    return out;
}

fn commonPrefix(lhs: []const u8, rhs: []const u8) usize {
    const limit = @min(lhs.len, rhs.len);
    var len: usize = 0;
    while (len < limit and lhs[len] == rhs[len]) : (len += 1) {}
    return len;
}

fn startsWith(key: []const u8, prefix: []const u8) bool {
    return key.len >= prefix.len and std.mem.eql(u8, key[0..prefix.len], prefix);
}

fn concat(context: anytype, lhs: []const u8, rhs: []const u8) AllocUpdateError![]u8 {
    const len = std.math.add(usize, lhs.len, rhs.len) catch return error.ResourceLimitExceeded;
    const out = try context.alloc(u8, len);
    @memcpy(out[0..lhs.len], lhs);
    @memcpy(out[lhs.len..], rhs);
    return out;
}

fn prepend(context: anytype, first: u8, tail: []const u8) AllocUpdateError![]u8 {
    const out = try context.alloc(u8, std.math.add(usize, 1, tail.len) catch
        return error.ResourceLimitExceeded);
    out[0] = first;
    @memcpy(out[1..], tail);
    return out;
}

fn oneNibble(context: anytype, value: u8) Allocator.Error![]u8 {
    const out = try context.alloc(u8, 1);
    out[0] = value;
    return out;
}
