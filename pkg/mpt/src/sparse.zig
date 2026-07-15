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
        path: []const u8,
        value: []const u8,
    };

    const Extension = struct {
        path: []const u8,
        child: *SparseNode,
    };

    const Branch = struct {
        children: [16]?*SparseNode,
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
    target: *SparseNode,
    encoded: []const u8,
    require_branch: bool,
};

const DeleteFrame = union(enum) {
    extension: *SparseNode,
    branch: struct {
        parent: *SparseNode,
        child_index: u8,
    },
};

const EncodeFrame = struct {
    node: *SparseNode,
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
        compact_buffer: std.ArrayList(u8) = .empty,
        node_buffer: std.ArrayList(u8) = .empty,
        steps: usize = 0,
        nodes: usize = 0,

        const Self = @This();

        fn deinit(self: *Self) void {
            self.compact_buffer.deinit(self.allocator);
            self.node_buffer.deinit(self.allocator);
        }

        fn step(self: *Self) UpdateError!void {
            self.steps = std.math.add(usize, self.steps, 1) catch
                return error.ResourceLimitExceeded;
        }

        fn newNode(self: *Self, kind: SparseNode.Kind) AllocUpdateError!*SparseNode {
            self.nodes = std.math.add(usize, self.nodes, 1) catch
                return error.ResourceLimitExceeded;
            const pointer = try self.allocator.create(SparseNode);
            pointer.* = .{ .kind = kind };
            return pointer;
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

fn decodeNode(context: anytype, encoded: []const u8) AllocUpdateError!*SparseNode {
    const root = try context.newNode(.empty);
    try decodeInto(context, root, encoded);
    return root;
}

fn decodeInto(context: anytype, root: *SparseNode, encoded: []const u8) AllocUpdateError!void {
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
    target: *SparseNode,
    leaf: node_codec.Node.Leaf,
) AllocUpdateError!void {
    const owned_path = try copyCompactPath(context, leaf.path);
    target.* = .{ .kind = .{ .leaf = .{ .path = owned_path, .value = leaf.value } } };
}

fn decodeExtensionNode(
    context: anytype,
    frames: *std.ArrayList(WorkFrame),
    target: *SparseNode,
    extension: node_codec.Node.Extension,
) AllocUpdateError!void {
    const owned_path = try copyCompactPath(context, extension.path);
    const child = (try decodeChildReference(context, frames, extension.child, true)) orelse
        return error.InvalidNodeReference;
    target.* = .{ .kind = .{ .extension = .{ .path = owned_path, .child = child } } };
}

fn decodeBranchNode(
    context: anytype,
    frames: *std.ArrayList(WorkFrame),
    target: *SparseNode,
    decoded: node_codec.Node.Branch,
) AllocUpdateError!void {
    var branch = emptyBranch();
    for (decoded.children, 0..) |reference, child_index| {
        branch.children[child_index] = try decodeChildReference(context, frames, reference, false);
    }
    branch.value = decoded.value;
    target.* = .{ .kind = .{ .branch = branch } };
}

fn decodeChildReference(
    context: anytype,
    frames: *std.ArrayList(WorkFrame),
    reference: node_codec.Reference,
    require_branch: bool,
) AllocUpdateError!?*SparseNode {
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

fn copyCompactPath(context: anytype, path: nibble.CompactPath) AllocUpdateError![]u8 {
    const owned = try context.alloc(u8, path.len);
    for (owned, 0..) |*path_nibble, index| path_nibble.* = path.nibbleAt(index);
    return owned;
}

fn materializeHash(context: anytype, sparse_node: *SparseNode) AllocUpdateError!void {
    switch (sparse_node.kind) {
        .hash => |digest| {
            const encoded = proof.find(context.index, digest) orelse return error.MissingNode;
            if (encoded.len < 32) return error.InvalidNodeReference;
            try decodeInto(context, sparse_node, encoded);
        },
        else => {},
    }
}

fn insert(context: anytype, node: *SparseNode, key: []const u8, value: []const u8) AllocUpdateError!void {
    var current = node;
    var remaining = key;
    while (true) {
        try context.step();
        try materializeHash(context, current);
        switch (current.kind) {
            .empty => {
                current.* = .{ .kind = .{ .leaf = .{ .path = remaining, .value = value } } };
                return;
            },
            .hash => unreachable,
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
                if (extension.child.kind == .hash) {
                    try materializeHash(context, extension.child);
                    if (extension.child.kind != .branch) return error.NonCanonicalNode;
                }
                current = extension.child;
                remaining = remaining[common..];
            },
            .branch => |branch| {
                if (remaining.len == 0) {
                    var next = branch;
                    next.value = value;
                    current.* = .{ .kind = .{ .branch = next } };
                    return;
                }
                const child_index = remaining[0];
                const child = branch.children[child_index] orelse child: {
                    const created = try context.newNode(.empty);
                    var next = branch;
                    next.children[child_index] = created;
                    current.* = .{ .kind = .{ .branch = next } };
                    break :child created;
                };
                current = child;
                remaining = remaining[1..];
            },
        }
    }
}

fn insertIntoLeaf(context: anytype, node: *SparseNode, leaf: SparseNode.Leaf, key: []const u8, value: []const u8) AllocUpdateError!void {
    const common = commonPrefix(leaf.path, key);
    if (common == leaf.path.len and common == key.len) {
        node.* = .{ .kind = .{ .leaf = .{ .path = leaf.path, .value = value } } };
        return;
    }
    const branch_node = try splitValues(context, leaf.path[common..], leaf.value, key[common..], value);
    node.* = if (common == 0) branch_node.* else .{ .kind = .{ .extension = .{
        .path = key[0..common],
        .child = branch_node,
    } } };
}

fn splitExtension(
    context: anytype,
    node: *SparseNode,
    extension: SparseNode.Extension,
    key: []const u8,
    value: []const u8,
    common: usize,
) AllocUpdateError!void {
    var branch = emptyBranch();
    const old_remaining = extension.path[common..];
    branch.children[old_remaining[0]] = if (old_remaining.len == 1)
        extension.child
    else
        try context.newNode(.{ .extension = .{
            .path = old_remaining[1..],
            .child = extension.child,
        } });

    const new_remaining = key[common..];
    if (new_remaining.len == 0) {
        branch.value = value;
    } else {
        branch.children[new_remaining[0]] = try context.newNode(.{ .leaf = .{
            .path = new_remaining[1..],
            .value = value,
        } });
    }

    const branch_node = try context.newNode(.{ .branch = branch });
    node.* = if (common == 0) branch_node.* else .{ .kind = .{ .extension = .{
        .path = key[0..common],
        .child = branch_node,
    } } };
}

fn splitValues(
    context: anytype,
    old_path: []const u8,
    old_value: []const u8,
    new_path: []const u8,
    new_value: []const u8,
) AllocUpdateError!*SparseNode {
    var branch = emptyBranch();
    if (old_path.len == 0) {
        branch.value = old_value;
    } else {
        branch.children[old_path[0]] = try context.newNode(.{ .leaf = .{
            .path = old_path[1..],
            .value = old_value,
        } });
    }
    if (new_path.len == 0) {
        branch.value = new_value;
    } else {
        branch.children[new_path[0]] = try context.newNode(.{ .leaf = .{
            .path = new_path[1..],
            .value = new_value,
        } });
    }
    return context.newNode(.{ .branch = branch });
}

fn delete(context: anytype, node: *SparseNode, key: []const u8) AllocUpdateError!void {
    var current = node;
    var remaining = key;
    var frames: std.ArrayList(WorkFrame) = .empty;
    defer frames.deinit(context.allocator);

    while (true) {
        try context.step();
        try materializeHash(context, current);
        switch (current.kind) {
            .empty => return,
            .hash => unreachable,
            .leaf => |leaf| {
                if (!std.mem.eql(u8, leaf.path, remaining)) return;
                current.* = .{ .kind = .empty };
                break;
            },
            .extension => |extension| {
                if (!startsWith(remaining, extension.path)) return;
                if (extension.child.kind == .hash) {
                    try materializeHash(context, extension.child);
                    if (extension.child.kind != .branch) return error.NonCanonicalNode;
                }
                try frames.append(context.allocator, .{ .delete = .{ .extension = current } });
                current = extension.child;
                remaining = remaining[extension.path.len..];
            },
            .branch => |branch| {
                if (remaining.len == 0) {
                    if (branch.value == null) return;
                    var next = branch;
                    next.value = null;
                    try compressBranch(context, current, next);
                    break;
                }
                const child_index = remaining[0];
                const child = branch.children[child_index] orelse return;
                try frames.append(context.allocator, .{ .delete = .{ .branch = .{
                    .parent = current,
                    .child_index = child_index,
                } } });
                current = child;
                remaining = remaining[1..];
            },
        }
    }

    while (frames.pop()) |work| {
        try context.step();
        switch (work.delete) {
            .extension => |parent| {
                const extension = switch (parent.kind) {
                    .extension => |value| value,
                    else => unreachable,
                };
                try compressExtension(context, parent, extension);
            },
            .branch => |frame| {
                var branch = switch (frame.parent.kind) {
                    .branch => |value| value,
                    else => unreachable,
                };
                const child = branch.children[frame.child_index].?;
                if (child.kind == .empty) branch.children[frame.child_index] = null;
                try compressBranch(context, frame.parent, branch);
            },
        }
    }
}

fn compressExtension(context: anytype, node: *SparseNode, extension: SparseNode.Extension) AllocUpdateError!void {
    switch (extension.child.kind) {
        .empty => node.* = .{ .kind = .empty },
        .hash, .branch => node.* = .{ .kind = .{ .extension = extension } },
        .leaf => |leaf| node.* = .{ .kind = .{ .leaf = .{
            .path = try concat(context, extension.path, leaf.path),
            .value = leaf.value,
        } } },
        .extension => |child_extension| node.* = .{ .kind = .{ .extension = .{
            .path = try concat(context, extension.path, child_extension.path),
            .child = child_extension.child,
        } } },
    }
}

fn compressBranch(context: anytype, node: *SparseNode, branch: SparseNode.Branch) AllocUpdateError!void {
    var child_count: usize = 0;
    var only_child_index: usize = 0;
    var only_child: ?*SparseNode = null;
    for (branch.children, 0..) |child, index| {
        if (child == null) continue;
        child_count += 1;
        only_child_index = index;
        only_child = child;
    }

    if (branch.value) |value| {
        node.* = if (child_count == 0)
            .{ .kind = .{ .leaf = .{ .path = &.{}, .value = value } } }
        else
            .{ .kind = .{ .branch = branch } };
        return;
    }
    if (child_count == 0) {
        node.* = .{ .kind = .empty };
        return;
    }
    if (child_count > 1) {
        node.* = .{ .kind = .{ .branch = branch } };
        return;
    }

    const child = only_child.?;
    try materializeHash(context, child);
    const child_nibble: u8 = @intCast(only_child_index);
    switch (child.kind) {
        .empty => node.* = .{ .kind = .empty },
        .hash => unreachable,
        .branch => node.* = .{ .kind = .{ .extension = .{
            .path = try oneNibble(context, child_nibble),
            .child = child,
        } } },
        .leaf => |leaf| node.* = .{ .kind = .{ .leaf = .{
            .path = try prepend(context, child_nibble, leaf.path),
            .value = leaf.value,
        } } },
        .extension => |extension| node.* = .{ .kind = .{ .extension = .{
            .path = try prepend(context, child_nibble, extension.path),
            .child = extension.child,
        } } },
    }
}

fn encodeRoot(context: anytype, root: *SparseNode) AllocUpdateError!hash.Root {
    if (root.kind == .empty) return hash.empty_root;

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

        if (!frame.expanded) switch (frame.node.kind) {
            .empty => {
                if (frame.is_root) return hash.empty_root;
                frame.node.reference = .empty;
                continue;
            },
            .hash => |digest| {
                if (frame.is_root) return error.InvalidNode;
                frame.node.reference = .{ .hashed = digest };
                continue;
            },
            .leaf => |leaf| {
                const lengths = try leafBufferLengths(leaf.path, leaf.value);
                const buffers = try context.buffers(lengths.compact, lengths.node);
                const encoded = try encodeLeaf(buffers.node, buffers.compact, leaf.path, leaf.value);
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

        const encoded = switch (frame.node.kind) {
            .extension => |extension| encoded: {
                const lengths = try extensionBufferLengths(extension.path, extension.child.reference);
                const buffers = try context.buffers(lengths.compact, lengths.node);
                break :encoded try encodeExtension(
                    buffers.node,
                    buffers.compact,
                    extension.path,
                    extension.child.reference,
                );
            },
            .branch => |branch| encoded: {
                const node_len = try branchBufferLength(branch);
                const buffers = try context.buffers(0, node_len);
                break :encoded try encodeBranch(buffers.node, branch);
            },
            else => unreachable,
        };
        try finishEncoding(context, frame.node, encoded, frame.is_root, &result);
    }
    return result orelse error.InvalidNode;
}

fn finishEncoding(
    context: anytype,
    node: *SparseNode,
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
        node.reference = .{ .embedded = embedded };
    } else {
        node.reference = .{ .hashed = context.keccak_context.keccak256(encoded) };
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

fn branchBufferLength(branch: SparseNode.Branch) UpdateError!usize {
    var payload = try bytesEncodedLen(branch.value orelse "");
    for (branch.children) |child| {
        const child_len = if (child) |present|
            try referenceEncodedLen(present.reference)
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

fn encodeBranch(node_buffer: []u8, branch: SparseNode.Branch) UpdateError![]const u8 {
    var payload_len = try bytesEncodedLen(branch.value orelse "");
    for (branch.children) |child| {
        if (child) |present| {
            if (present.reference == .unset or present.reference == .empty) return error.InvalidNode;
            payload_len = std.math.add(usize, payload_len, try referenceEncodedLen(present.reference)) catch
                return error.ResourceLimitExceeded;
        } else {
            payload_len = std.math.add(usize, payload_len, 1) catch
                return error.ResourceLimitExceeded;
        }
    }
    var writer = try listWriter(node_buffer, payload_len);
    for (branch.children) |child| {
        if (child) |present| {
            try writeReference(&writer, present.reference);
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

fn keyNibbles(context: anytype, key: []const u8) AllocUpdateError![]u8 {
    const len = std.math.mul(usize, key.len, 2) catch return error.ResourceLimitExceeded;
    const out = try context.alloc(u8, len);
    for (out, 0..) |*value, index| value.* = nibble.keyNibbleAt(key, index);
    return out;
}

fn emptyBranch() SparseNode.Branch {
    return .{ .children = [_]?*SparseNode{null} ** 16, .value = null };
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

fn prepend(context: anytype, value: u8, rest: []const u8) AllocUpdateError![]u8 {
    const len = std.math.add(usize, rest.len, 1) catch return error.ResourceLimitExceeded;
    const out = try context.alloc(u8, len);
    out[0] = value;
    @memcpy(out[1..], rest);
    return out;
}

fn oneNibble(context: anytype, value: u8) AllocUpdateError![]u8 {
    const out = try context.alloc(u8, 1);
    out[0] = value;
    return out;
}
