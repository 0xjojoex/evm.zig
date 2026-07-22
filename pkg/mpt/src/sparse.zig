//! Sparse (witness-backed) trie updates.
//!
//! Applies inserts and deletes to a trie represented only by the witness nodes
//! in a sealed `NodeIndex`, materializing hashed children on demand, and
//! returns the new root. All transient storage comes from the allocator passed
//! to `Trie.init`; a fixed allocator is the bounded mode.

const std = @import("std");
const rlp = @import("rlp");

const errors = @import("error.zig");
const UpdateError = errors.UpdateError;
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");
const node_codec = @import("node.zig");
const proof = @import("proof.zig");
const Allocator = std.mem.Allocator;
const AllocUpdateError = Allocator.Error || UpdateError;
const NodeId = u32;

const PathRange = struct {
    start: usize,
    len: usize,

    fn suffix(self: PathRange, start: usize) PathRange {
        std.debug.assert(start <= self.len);
        return .{ .start = self.start + start, .len = self.len - start };
    }

    fn prefix(self: PathRange, len: usize) PathRange {
        std.debug.assert(len <= self.len);
        return .{ .start = self.start, .len = len };
    }
};

/// A single update: set `key` to `value`, or delete `key` when `value` is null.
pub const Update = struct {
    key: []const u8,
    value: ?[]const u8,
};

const SparseNode = struct {
    kind: Kind,
    reference: Reference = .unset,

    const Kind = union(enum) {
        empty,
        hash: hash.Root,
        leaf: Leaf,
        extension: Extension,
        branch: Branch,
    };

    const Leaf = struct {
        path: PathRange,
        value: []const u8,
    };

    const Extension = struct {
        path: PathRange,
        child: NodeId,
    };

    const Branch = struct {
        children: [16]?NodeId,
        value: ?[]const u8,
    };
};

const Reference = union(enum) {
    unset,
    empty,
    embedded: Embedded,
    hashed: hash.Root,

    const Embedded = struct {
        len: u8,
        bytes: [31]u8,
    };
};

const DecodeTask = struct {
    target: NodeId,
    encoded: []const u8,
    require_branch: bool,
};

const DeleteFrame = union(enum) {
    extension: NodeId,
    branch: struct {
        parent: NodeId,
        child_index: u8,
    },
};

const EncodeFrame = struct {
    node: NodeId,
    expanded: bool,
    is_root: bool,
};

const WorkFrame = union(enum) {
    decode: DecodeTask,
    delete: DeleteFrame,
    encode: EncodeFrame,
};

fn Context(comptime KeccakContext: type) type {
    return struct {
        allocator: Allocator,
        keccak_context: KeccakContext,
        index: *const proof.NodeIndex,
        nodes: std.ArrayList(SparseNode) = .empty,
        path_bytes: std.ArrayList(u8) = .empty,
        compact_buffer: std.ArrayList(u8) = .empty,
        node_buffer: std.ArrayList(u8) = .empty,
        steps: usize = 0,

        const Self = @This();

        fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.path_bytes.deinit(self.allocator);
            self.compact_buffer.deinit(self.allocator);
            self.node_buffer.deinit(self.allocator);
        }

        fn step(self: *Self) UpdateError!void {
            self.steps = std.math.add(usize, self.steps, 1) catch
                return error.ResourceLimitExceeded;
        }

        fn newNode(self: *Self, kind: SparseNode.Kind) AllocUpdateError!NodeId {
            if (self.nodes.items.len >= std.math.maxInt(NodeId)) {
                return error.ResourceLimitExceeded;
            }
            const id: NodeId = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{ .kind = kind });
            return id;
        }

        fn node(self: *Self, id: NodeId) *SparseNode {
            return &self.nodes.items[@intCast(id)];
        }

        fn nodeValue(self: *const Self, id: NodeId) SparseNode {
            return self.nodes.items[@intCast(id)];
        }

        fn path(self: *const Self, range: PathRange) []const u8 {
            std.debug.assert(range.start <= self.path_bytes.items.len);
            std.debug.assert(range.len <= self.path_bytes.items.len - range.start);
            return self.path_bytes.items[range.start..][0..range.len];
        }

        fn concatPaths(self: *Self, lhs: PathRange, rhs: PathRange) AllocUpdateError!PathRange {
            const len = std.math.add(usize, lhs.len, rhs.len) catch
                return error.ResourceLimitExceeded;
            try self.path_bytes.ensureUnusedCapacity(self.allocator, len);
            const start = self.path_bytes.items.len;
            self.path_bytes.appendSliceAssumeCapacity(self.path(lhs));
            self.path_bytes.appendSliceAssumeCapacity(self.path(rhs));
            return .{ .start = start, .len = len };
        }

        fn prependPath(self: *Self, value: u8, rest: PathRange) AllocUpdateError!PathRange {
            const len = std.math.add(usize, rest.len, 1) catch
                return error.ResourceLimitExceeded;
            try self.path_bytes.ensureUnusedCapacity(self.allocator, len);
            const start = self.path_bytes.items.len;
            self.path_bytes.appendAssumeCapacity(value);
            self.path_bytes.appendSliceAssumeCapacity(self.path(rest));
            return .{ .start = start, .len = len };
        }

        fn oneNibblePath(self: *Self, value: u8) Allocator.Error!PathRange {
            const start = self.path_bytes.items.len;
            try self.path_bytes.append(self.allocator, value);
            return .{ .start = start, .len = 1 };
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

/// Apply `updates` (sorted ascending by key; a null value deletes the key) to
/// the trie rooted at `root_hash` within `index`, returning the new root.
pub fn updateSorted(
    keccak_context: anytype,
    backing_allocator: Allocator,
    root_hash: hash.Root,
    index: *const proof.NodeIndex,
    updates: []const Update,
) AllocUpdateError!hash.Root {
    try validateUpdates(updates, true);
    if (updates.len == 0) return root_hash;

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var context: Context(@TypeOf(keccak_context)) = .{
        .allocator = allocator,
        .keccak_context = keccak_context,
        .index = index,
    };
    defer context.deinit();

    const root_node = if (std.mem.eql(u8, &root_hash, &hash.empty_root))
        try context.newNode(.empty)
    else root: {
        const encoded = proof.find(index, root_hash) orelse return error.MissingNode;
        break :root try decodeNode(&context, encoded);
    };

    for (updates) |update| {
        const path = try keyNibbles(&context, update.key);
        if (update.value) |value| {
            try insert(&context, root_node, path, value);
        } else {
            try delete(&context, root_node, path);
        }
    }

    return encodeRoot(&context, root_node);
}

pub fn validateUpdates(updates: []const Update, sorted: bool) errors.InputError!void {
    for (updates) |update| {
        if (update.value) |value| {
            if (value.len == 0) return error.EmptyValue;
        }
    }
    if (!sorted) return;
    for (updates[1..], 1..) |update, index| {
        switch (std.mem.order(u8, updates[index - 1].key, update.key)) {
            .lt => {},
            .eq => return error.DuplicateKey,
            .gt => return error.UnsortedKeys,
        }
    }
}

fn decodeNode(context: anytype, encoded: []const u8) AllocUpdateError!NodeId {
    const root = try context.newNode(.empty);
    try decodeInto(context, root, encoded);
    return root;
}

fn decodeInto(context: anytype, root: NodeId, encoded: []const u8) AllocUpdateError!void {
    var frames: std.ArrayList(WorkFrame) = .empty;
    defer frames.deinit(context.allocator);
    try frames.append(context.allocator, .{ .decode = .{
        .target = root,
        .encoded = encoded,
        .require_branch = false,
    } });

    while (frames.pop()) |work| {
        const task = work.decode;
        try context.step();
        const decoded = try node_codec.decode(task.encoded, task.require_branch);
        switch (decoded) {
            .leaf => |leaf| try decodeLeafNode(context, task.target, leaf),
            .extension => |extension| try decodeExtensionNode(
                context,
                &frames,
                task.target,
                extension,
            ),
            .branch => |branch| try decodeBranchNode(
                context,
                &frames,
                task.target,
                branch,
            ),
        }
    }
}

fn decodeLeafNode(
    context: anytype,
    target: NodeId,
    leaf: node_codec.Node.Leaf,
) AllocUpdateError!void {
    const owned_path = try copyCompactPath(context, leaf.path);
    context.node(target).* = .{ .kind = .{ .leaf = .{ .path = owned_path, .value = leaf.value } } };
}

fn decodeExtensionNode(
    context: anytype,
    frames: *std.ArrayList(WorkFrame),
    target: NodeId,
    extension: node_codec.Node.Extension,
) AllocUpdateError!void {
    const owned_path = try copyCompactPath(context, extension.path);
    const child = (try decodeChildReference(context, frames, extension.child, true)) orelse
        return error.InvalidNodeReference;
    context.node(target).* = .{ .kind = .{ .extension = .{ .path = owned_path, .child = child } } };
}

fn decodeBranchNode(
    context: anytype,
    frames: *std.ArrayList(WorkFrame),
    target: NodeId,
    decoded: node_codec.Node.Branch,
) AllocUpdateError!void {
    var branch = emptyBranch();
    for (decoded.children, 0..) |reference, child_index| {
        branch.children[child_index] = try decodeChildReference(context, frames, reference, false);
    }
    branch.value = decoded.value;
    context.node(target).* = .{ .kind = .{ .branch = branch } };
}

fn decodeChildReference(
    context: anytype,
    frames: *std.ArrayList(WorkFrame),
    reference: node_codec.Reference,
    require_branch: bool,
) AllocUpdateError!?NodeId {
    return switch (reference) {
        .empty => null,
        .embedded => |encoded| {
            const child = try context.newNode(.empty);
            try frames.append(context.allocator, .{ .decode = .{
                .target = child,
                .encoded = encoded,
                .require_branch = require_branch,
            } });
            return child;
        },
        .hashed => |digest| try context.newNode(.{ .hash = digest }),
    };
}

fn copyCompactPath(context: anytype, path: nibble.CompactPath) AllocUpdateError!PathRange {
    const start = context.path_bytes.items.len;
    try context.path_bytes.ensureUnusedCapacity(context.allocator, path.len);
    for (0..path.len) |index| context.path_bytes.appendAssumeCapacity(path.nibbleAt(index));
    return .{ .start = start, .len = path.len };
}

fn materializeHash(context: anytype, node_id: NodeId) AllocUpdateError!void {
    switch (context.nodeValue(node_id).kind) {
        .hash => |digest| {
            const encoded = proof.find(context.index, digest) orelse return error.MissingNode;
            if (encoded.len < 32) return error.InvalidNodeReference;
            try decodeInto(context, node_id, encoded);
        },
        else => {},
    }
}

fn insert(context: anytype, node: NodeId, key: PathRange, value: []const u8) AllocUpdateError!void {
    var current = node;
    var remaining = key;
    while (true) {
        try context.step();
        try materializeHash(context, current);
        switch (context.nodeValue(current).kind) {
            .empty => {
                context.node(current).* = .{ .kind = .{ .leaf = .{ .path = remaining, .value = value } } };
                return;
            },
            .hash => unreachable,
            .leaf => |leaf| {
                try insertIntoLeaf(context, current, leaf, remaining, value);
                return;
            },
            .extension => |extension| {
                const common = commonPrefix(context.path(extension.path), context.path(remaining));
                if (common != extension.path.len) {
                    try splitExtension(context, current, extension, remaining, value, common);
                    return;
                }
                if (context.nodeValue(extension.child).kind == .hash) {
                    try materializeHash(context, extension.child);
                    if (context.nodeValue(extension.child).kind != .branch) return error.NonCanonicalNode;
                }
                current = extension.child;
                remaining = remaining.suffix(common);
            },
            .branch => |branch| {
                if (remaining.len == 0) {
                    var next = branch;
                    next.value = value;
                    context.node(current).* = .{ .kind = .{ .branch = next } };
                    return;
                }
                const child_index = context.path(remaining)[0];
                const child = branch.children[child_index] orelse child: {
                    const created = try context.newNode(.empty);
                    var next = branch;
                    next.children[child_index] = created;
                    context.node(current).* = .{ .kind = .{ .branch = next } };
                    break :child created;
                };
                current = child;
                remaining = remaining.suffix(1);
            },
        }
    }
}

fn insertIntoLeaf(context: anytype, node: NodeId, leaf: SparseNode.Leaf, key: PathRange, value: []const u8) AllocUpdateError!void {
    const common = commonPrefix(context.path(leaf.path), context.path(key));
    if (common == leaf.path.len and common == key.len) {
        context.node(node).* = .{ .kind = .{ .leaf = .{ .path = leaf.path, .value = value } } };
        return;
    }
    const branch = try splitValues(
        context,
        leaf.path.suffix(common),
        leaf.value,
        key.suffix(common),
        value,
    );
    if (common == 0) {
        context.node(node).* = .{ .kind = .{ .branch = branch } };
    } else {
        const branch_node = try context.newNode(.{ .branch = branch });
        context.node(node).* = .{ .kind = .{ .extension = .{
            .path = key.prefix(common),
            .child = branch_node,
        } } };
    }
}

fn splitExtension(
    context: anytype,
    node: NodeId,
    extension: SparseNode.Extension,
    key: PathRange,
    value: []const u8,
    common: usize,
) AllocUpdateError!void {
    var branch = emptyBranch();
    const old_remaining = extension.path.suffix(common);
    const old_child_index = context.path(old_remaining)[0];
    branch.children[old_child_index] = if (old_remaining.len == 1)
        extension.child
    else
        try context.newNode(.{ .extension = .{
            .path = old_remaining.suffix(1),
            .child = extension.child,
        } });

    const new_remaining = key.suffix(common);
    if (new_remaining.len == 0) {
        branch.value = value;
    } else {
        const new_child_index = context.path(new_remaining)[0];
        branch.children[new_child_index] = try context.newNode(.{ .leaf = .{
            .path = new_remaining.suffix(1),
            .value = value,
        } });
    }

    if (common == 0) {
        context.node(node).* = .{ .kind = .{ .branch = branch } };
    } else {
        const branch_node = try context.newNode(.{ .branch = branch });
        context.node(node).* = .{ .kind = .{ .extension = .{
            .path = key.prefix(common),
            .child = branch_node,
        } } };
    }
}

fn splitValues(
    context: anytype,
    old_path: PathRange,
    old_value: []const u8,
    new_path: PathRange,
    new_value: []const u8,
) AllocUpdateError!SparseNode.Branch {
    var branch = emptyBranch();
    if (old_path.len == 0) {
        branch.value = old_value;
    } else {
        const old_child_index = context.path(old_path)[0];
        branch.children[old_child_index] = try context.newNode(.{ .leaf = .{
            .path = old_path.suffix(1),
            .value = old_value,
        } });
    }
    if (new_path.len == 0) {
        branch.value = new_value;
    } else {
        const new_child_index = context.path(new_path)[0];
        branch.children[new_child_index] = try context.newNode(.{ .leaf = .{
            .path = new_path.suffix(1),
            .value = new_value,
        } });
    }
    return branch;
}

fn delete(context: anytype, node: NodeId, key: PathRange) AllocUpdateError!void {
    var current = node;
    var remaining = key;
    var frames: std.ArrayList(WorkFrame) = .empty;
    defer frames.deinit(context.allocator);

    while (true) {
        try context.step();
        try materializeHash(context, current);
        switch (context.nodeValue(current).kind) {
            .empty => return,
            .hash => unreachable,
            .leaf => |leaf| {
                if (!std.mem.eql(u8, context.path(leaf.path), context.path(remaining))) return;
                context.node(current).* = .{ .kind = .empty };
                break;
            },
            .extension => |extension| {
                if (!startsWith(context.path(remaining), context.path(extension.path))) return;
                if (context.nodeValue(extension.child).kind == .hash) {
                    try materializeHash(context, extension.child);
                    if (context.nodeValue(extension.child).kind != .branch) return error.NonCanonicalNode;
                }
                try frames.append(context.allocator, .{ .delete = .{ .extension = current } });
                current = extension.child;
                remaining = remaining.suffix(extension.path.len);
            },
            .branch => |branch| {
                if (remaining.len == 0) {
                    if (branch.value == null) return;
                    var next = branch;
                    next.value = null;
                    try compressBranch(context, current, next);
                    break;
                }
                const child_index = context.path(remaining)[0];
                const child = branch.children[child_index] orelse return;
                try frames.append(context.allocator, .{ .delete = .{ .branch = .{
                    .parent = current,
                    .child_index = child_index,
                } } });
                current = child;
                remaining = remaining.suffix(1);
            },
        }
    }

    while (frames.pop()) |work| {
        try context.step();
        switch (work.delete) {
            .extension => |parent| {
                const extension = switch (context.nodeValue(parent).kind) {
                    .extension => |value| value,
                    else => unreachable,
                };
                try compressExtension(context, parent, extension);
            },
            .branch => |frame| {
                var branch = switch (context.nodeValue(frame.parent).kind) {
                    .branch => |value| value,
                    else => unreachable,
                };
                const child = branch.children[frame.child_index].?;
                if (context.nodeValue(child).kind == .empty) branch.children[frame.child_index] = null;
                try compressBranch(context, frame.parent, branch);
            },
        }
    }
}

fn compressExtension(context: anytype, node: NodeId, extension: SparseNode.Extension) AllocUpdateError!void {
    switch (context.nodeValue(extension.child).kind) {
        .empty => context.node(node).* = .{ .kind = .empty },
        .hash, .branch => context.node(node).* = .{ .kind = .{ .extension = extension } },
        .leaf => |leaf| {
            const path = try context.concatPaths(extension.path, leaf.path);
            context.node(node).* = .{ .kind = .{ .leaf = .{
                .path = path,
                .value = leaf.value,
            } } };
        },
        .extension => |child_extension| {
            const path = try context.concatPaths(extension.path, child_extension.path);
            context.node(node).* = .{ .kind = .{ .extension = .{
                .path = path,
                .child = child_extension.child,
            } } };
        },
    }
}

fn compressBranch(context: anytype, node: NodeId, branch: SparseNode.Branch) AllocUpdateError!void {
    var child_count: usize = 0;
    var only_child_index: usize = 0;
    var only_child: ?NodeId = null;
    for (branch.children, 0..) |child, index| {
        if (child == null) continue;
        child_count += 1;
        only_child_index = index;
        only_child = child;
    }

    if (branch.value) |value| {
        context.node(node).* = if (child_count == 0)
            .{ .kind = .{ .leaf = .{ .path = .{ .start = 0, .len = 0 }, .value = value } } }
        else
            .{ .kind = .{ .branch = branch } };
        return;
    }
    if (child_count == 0) {
        context.node(node).* = .{ .kind = .empty };
        return;
    }
    if (child_count > 1) {
        context.node(node).* = .{ .kind = .{ .branch = branch } };
        return;
    }

    const child = only_child.?;
    try materializeHash(context, child);
    const child_nibble: u8 = @intCast(only_child_index);
    switch (context.nodeValue(child).kind) {
        .empty => context.node(node).* = .{ .kind = .empty },
        .hash => unreachable,
        .branch => {
            const path = try context.oneNibblePath(child_nibble);
            context.node(node).* = .{ .kind = .{ .extension = .{
                .path = path,
                .child = child,
            } } };
        },
        .leaf => |leaf| {
            const path = try context.prependPath(child_nibble, leaf.path);
            context.node(node).* = .{ .kind = .{ .leaf = .{
                .path = path,
                .value = leaf.value,
            } } };
        },
        .extension => |extension| {
            const path = try context.prependPath(child_nibble, extension.path);
            context.node(node).* = .{ .kind = .{ .extension = .{
                .path = path,
                .child = extension.child,
            } } };
        },
    }
}

fn encodeRoot(context: anytype, root: NodeId) AllocUpdateError!hash.Root {
    if (context.nodeValue(root).kind == .empty) return hash.empty_root;

    var frames: std.ArrayList(WorkFrame) = .empty;
    defer frames.deinit(context.allocator);
    var result: ?hash.Root = null;
    try frames.append(context.allocator, .{ .encode = .{
        .node = root,
        .expanded = false,
        .is_root = true,
    } });

    while (frames.pop()) |work| {
        const frame = work.encode;
        try context.step();

        if (!frame.expanded) switch (context.nodeValue(frame.node).kind) {
            .empty => {
                if (frame.is_root) return hash.empty_root;
                context.node(frame.node).reference = .empty;
                continue;
            },
            .hash => |digest| {
                if (frame.is_root) return error.InvalidNode;
                context.node(frame.node).reference = .{ .hashed = digest };
                continue;
            },
            .leaf => |leaf| {
                const lengths = try leafBufferLengths(context.path(leaf.path), leaf.value);
                const buffers = try context.buffers(lengths.compact, lengths.node);
                const encoded = try encodeLeaf(
                    buffers.node,
                    buffers.compact,
                    context.path(leaf.path),
                    leaf.value,
                );
                try finishEncoding(context, frame.node, encoded, frame.is_root, &result);
                continue;
            },
            .extension => |extension| {
                try frames.append(context.allocator, .{ .encode = .{
                    .node = frame.node,
                    .expanded = true,
                    .is_root = frame.is_root,
                } });
                try frames.append(context.allocator, .{ .encode = .{
                    .node = extension.child,
                    .expanded = false,
                    .is_root = false,
                } });
                continue;
            },
            .branch => |branch| {
                try frames.append(context.allocator, .{ .encode = .{
                    .node = frame.node,
                    .expanded = true,
                    .is_root = frame.is_root,
                } });
                var index: usize = branch.children.len;
                while (index > 0) {
                    index -= 1;
                    if (branch.children[index]) |child| {
                        try frames.append(context.allocator, .{ .encode = .{
                            .node = child,
                            .expanded = false,
                            .is_root = false,
                        } });
                    }
                }
                continue;
            },
        };

        const encoded = switch (context.nodeValue(frame.node).kind) {
            .extension => |extension| encoded: {
                const child_reference = context.nodeValue(extension.child).reference;
                const lengths = try extensionBufferLengths(context.path(extension.path), child_reference);
                const buffers = try context.buffers(lengths.compact, lengths.node);
                break :encoded try encodeExtension(
                    buffers.node,
                    buffers.compact,
                    context.path(extension.path),
                    child_reference,
                );
            },
            .branch => |branch| encoded: {
                const node_len = try branchBufferLength(context, branch);
                const buffers = try context.buffers(0, node_len);
                break :encoded try encodeBranch(context, buffers.node, branch);
            },
            else => unreachable,
        };
        try finishEncoding(context, frame.node, encoded, frame.is_root, &result);
    }
    return result orelse error.InvalidNode;
}

fn finishEncoding(
    context: anytype,
    node: NodeId,
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
        context.node(node).reference = .{ .embedded = embedded };
    } else {
        context.node(node).reference = .{ .hashed = context.keccak_context.keccak256(encoded) };
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

fn extensionBufferLengths(path: []const u8, child_reference: Reference) UpdateError!BufferLengths {
    const compact = try compactOutputLen(path);
    const payload = try addEncodedLengths(&.{
        try bytesEncodedLenUpperBound(compact),
        try referenceEncodedLen(child_reference),
    });
    return .{ .compact = compact, .node = try listEncodedLen(payload) };
}

fn branchBufferLength(context: anytype, branch: SparseNode.Branch) UpdateError!usize {
    var payload = try bytesEncodedLen(branch.value orelse "");
    for (branch.children) |child| {
        const child_len = if (child) |present|
            try referenceEncodedLen(context.nodeValue(present).reference)
        else
            1;
        payload = std.math.add(usize, payload, child_len) catch
            return error.ResourceLimitExceeded;
    }
    return listEncodedLen(payload);
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

fn listEncodedLen(payload_len: usize) UpdateError!usize {
    return std.math.add(usize, listPrefixLen(payload_len), payload_len) catch
        error.ResourceLimitExceeded;
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
    child_reference: Reference,
) UpdateError![]const u8 {
    if (child_reference == .unset or child_reference == .empty) return error.InvalidNode;
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

fn encodeBranch(context: anytype, node_buffer: []u8, branch: SparseNode.Branch) UpdateError![]const u8 {
    var payload_len = try bytesEncodedLen(branch.value orelse "");
    for (branch.children) |child| {
        if (child) |present| {
            const reference = context.nodeValue(present).reference;
            if (reference == .unset or reference == .empty) return error.InvalidNode;
            payload_len = std.math.add(usize, payload_len, try referenceEncodedLen(reference)) catch
                return error.ResourceLimitExceeded;
        } else {
            payload_len = std.math.add(usize, payload_len, 1) catch
                return error.ResourceLimitExceeded;
        }
    }
    var writer = try listWriter(node_buffer, payload_len);
    for (branch.children) |child| {
        if (child) |present| {
            try writeReference(&writer, context.nodeValue(present).reference);
        } else {
            try writeBytes(&writer, "");
        }
    }
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

fn writeReference(writer: *rlp.Writer, reference: Reference) UpdateError!void {
    switch (reference) {
        .unset, .empty => return error.InvalidNode,
        .hashed => |digest| try writeBytes(writer, &digest),
        .embedded => |embedded| {
            const item = try rlp.parseExact(embedded.bytes[0..embedded.len]);
            writer.raw(item) catch |err| switch (err) {
                error.NoSpaceLeft => return error.ResourceLimitExceeded,
                error.OutOfMemory => unreachable,
            };
        },
    }
}

fn referenceEncodedLen(reference: Reference) UpdateError!usize {
    return switch (reference) {
        .unset, .empty => error.InvalidNode,
        .hashed => 33,
        .embedded => |embedded| embedded.len,
    };
}

fn bytesEncodedLen(value: []const u8) UpdateError!usize {
    if (value.len == 1 and value[0] < 0x80) return 1;
    const prefix_len: usize = if (value.len < 56) 1 else std.math.add(usize, 1, lengthByteLen(value.len)) catch
        return error.ResourceLimitExceeded;
    return std.math.add(usize, prefix_len, value.len) catch
        return error.ResourceLimitExceeded;
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

fn keyNibbles(context: anytype, key: []const u8) AllocUpdateError!PathRange {
    const len = std.math.mul(usize, key.len, 2) catch return error.ResourceLimitExceeded;
    const start = context.path_bytes.items.len;
    try context.path_bytes.ensureUnusedCapacity(context.allocator, len);
    for (0..len) |index| context.path_bytes.appendAssumeCapacity(nibble.keyNibbleAt(key, index));
    return .{ .start = start, .len = len };
}

fn emptyBranch() SparseNode.Branch {
    return .{ .children = [_]?NodeId{null} ** 16, .value = null };
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
