//! Sparse (witness-backed) trie updates over a sealed hash `NodeIndex`.
//!
//! Applies inserts and deletes to a trie represented only by the witness nodes
//! in a sealed `NodeIndex`, materializing hashed children on demand, and
//! returns the new root. All transient storage comes from the allocator passed
//! to `Trie.init`; a fixed allocator is the bounded mode.
//!
//! This engine needs no authenticated catalog, so it serves validation lanes
//! that discover touched keys only during execution. Catalog-backed updates
//! live in the occurrence engine.

const std = @import("std");

const encode = @import("encode.zig");
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

const Reference = encode.Reference;

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
        /// Hashed siblings stay borrowed until an update selects them.
        children: [16]BranchChild,
        value: ?[]const u8,
    };

    const BranchChild = union(enum) {
        empty,
        hash: node_codec.HashedReference,
        node: *SparseNode,
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

        fn decodeNode(self: *Self, encoded: []const u8) AllocUpdateError!*SparseNode {
            const root = try self.newNode(.empty);
            try self.decodeInto(root, encoded);
            return root;
        }

        fn decodeInto(self: *Self, root: *SparseNode, encoded: []const u8) AllocUpdateError!void {
            var frames: std.ArrayList(WorkFrame) = .empty;
            defer frames.deinit(self.allocator);
            try frames.append(self.allocator, .{ .decode = .{
                .target = root,
                .encoded = encoded,
                .require_branch = false,
            } });

            while (frames.pop()) |work| {
                const task = work.decode;
                try self.step();
                const decoded = try node_codec.decode(task.encoded, task.require_branch);
                switch (decoded) {
                    .leaf => |leaf| try self.decodeLeafNode(task.target, leaf),
                    .extension => |extension| try self.decodeExtensionNode(
                        &frames,
                        task.target,
                        extension,
                    ),
                    .branch => |branch| try self.decodeBranchNode(
                        &frames,
                        task.target,
                        branch,
                    ),
                }
            }
        }

        fn decodeLeafNode(
            self: *Self,
            target: *SparseNode,
            leaf: node_codec.Node.Leaf,
        ) AllocUpdateError!void {
            const owned_path = try self.copyCompactPath(leaf.path);
            target.* = .{ .kind = .{ .leaf = .{ .path = owned_path, .value = leaf.value } } };
        }

        fn decodeExtensionNode(
            self: *Self,
            frames: *std.ArrayList(WorkFrame),
            target: *SparseNode,
            extension: node_codec.Node.Extension,
        ) AllocUpdateError!void {
            const owned_path = try self.copyCompactPath(extension.path);
            const child = (try self.decodeChildReference(frames, extension.child, true)) orelse
                return error.InvalidNodeReference;
            target.* = .{ .kind = .{ .extension = .{ .path = owned_path, .child = child } } };
        }

        fn decodeBranchNode(
            self: *Self,
            frames: *std.ArrayList(WorkFrame),
            target: *SparseNode,
            decoded: node_codec.Node.Branch,
        ) AllocUpdateError!void {
            var branch = emptyBranch();
            for (decoded.children, 0..) |reference, child_index| {
                branch.children[child_index] = switch (reference) {
                    .empty => .empty,
                    .hashed => |digest| .{ .hash = digest },
                    .embedded => |encoded| child: {
                        const child = try self.newNode(.empty);
                        try frames.append(self.allocator, .{ .decode = .{
                            .target = child,
                            .encoded = encoded,
                            .require_branch = false,
                        } });
                        break :child .{ .node = child };
                    },
                };
            }
            branch.value = decoded.value;
            target.* = .{ .kind = .{ .branch = branch } };
        }

        fn decodeChildReference(
            self: *Self,
            frames: *std.ArrayList(WorkFrame),
            reference: node_codec.Reference,
            require_branch: bool,
        ) AllocUpdateError!?*SparseNode {
            return switch (reference) {
                .empty => null,
                .embedded => |encoded| {
                    const child = try self.newNode(.empty);
                    try frames.append(self.allocator, .{ .decode = .{
                        .target = child,
                        .encoded = encoded,
                        .require_branch = require_branch,
                    } });
                    return child;
                },
                .hashed => |digest| try self.newNode(.{ .hash = digest.* }),
            };
        }

        fn copyCompactPath(self: *Self, path: nibble.CompactPath) AllocUpdateError![]u8 {
            const owned = try self.alloc(u8, path.len);
            for (owned, 0..) |*path_nibble, index| path_nibble.* = path.nibbleAt(index);
            return owned;
        }

        fn materializeNode(self: *Self, sparse_node: *SparseNode) AllocUpdateError!void {
            switch (sparse_node.kind) {
                .hash => |digest| {
                    const encoded = proof.find(self.index, digest) orelse return error.MissingNode;
                    if (encoded.len < 32) return error.InvalidNodeReference;
                    try self.decodeInto(sparse_node, encoded);
                },
                else => {},
            }
        }

        fn branchChildNode(
            self: *Self,
            child: *SparseNode.BranchChild,
        ) AllocUpdateError!?*SparseNode {
            return switch (child.*) {
                .empty => null,
                .node => |node| node,
                .hash => |digest| node: {
                    const node = try self.newNode(.{ .hash = digest.* });
                    child.* = .{ .node = node };
                    break :node node;
                },
            };
        }

        fn insert(self: *Self, node: *SparseNode, key: []const u8, value: []const u8) AllocUpdateError!void {
            var current = node;
            var remaining = key;
            while (true) {
                try self.step();
                try self.materializeNode(current);
                switch (current.kind) {
                    .empty => {
                        current.* = .{ .kind = .{ .leaf = .{ .path = remaining, .value = value } } };
                        return;
                    },
                    .hash => unreachable,
                    .leaf => |leaf| {
                        try self.insertIntoLeaf(current, leaf, remaining, value);
                        return;
                    },
                    .extension => |extension| {
                        const common = nibble.commonPrefix(extension.path, remaining);
                        if (common != extension.path.len) {
                            try self.splitExtension(current, extension, remaining, value, common);
                            return;
                        }
                        if (extension.child.kind == .hash) {
                            try self.materializeNode(extension.child);
                            if (extension.child.kind != .branch) return error.NonCanonicalNode;
                        }
                        current = extension.child;
                        remaining = remaining[common..];
                    },
                    .branch => |*branch| {
                        if (remaining.len == 0) {
                            branch.value = value;
                            return;
                        }
                        const child_index = remaining[0];
                        const child = (try self.branchChildNode(&branch.children[child_index])) orelse child: {
                            const created = try self.newNode(.empty);
                            branch.children[child_index] = .{ .node = created };
                            break :child created;
                        };
                        current = child;
                        remaining = remaining[1..];
                    },
                }
            }
        }

        fn insertIntoLeaf(self: *Self, node: *SparseNode, leaf: SparseNode.Leaf, key: []const u8, value: []const u8) AllocUpdateError!void {
            const common = nibble.commonPrefix(leaf.path, key);
            if (common == leaf.path.len and common == key.len) {
                node.* = .{ .kind = .{ .leaf = .{ .path = leaf.path, .value = value } } };
                return;
            }
            const branch_node = try self.splitValues(leaf.path[common..], leaf.value, key[common..], value);
            node.* = if (common == 0) branch_node.* else .{ .kind = .{ .extension = .{
                .path = key[0..common],
                .child = branch_node,
            } } };
        }

        fn splitExtension(
            self: *Self,
            node: *SparseNode,
            extension: SparseNode.Extension,
            key: []const u8,
            value: []const u8,
            common: usize,
        ) AllocUpdateError!void {
            var branch = emptyBranch();
            const old_remaining = extension.path[common..];
            branch.children[old_remaining[0]] = .{ .node = if (old_remaining.len == 1)
                extension.child
            else
                try self.newNode(.{ .extension = .{
                    .path = old_remaining[1..],
                    .child = extension.child,
                } }) };

            const new_remaining = key[common..];
            if (new_remaining.len == 0) {
                branch.value = value;
            } else {
                branch.children[new_remaining[0]] = .{ .node = try self.newNode(.{ .leaf = .{
                    .path = new_remaining[1..],
                    .value = value,
                } }) };
            }

            const branch_node = try self.newNode(.{ .branch = branch });
            node.* = if (common == 0) branch_node.* else .{ .kind = .{ .extension = .{
                .path = key[0..common],
                .child = branch_node,
            } } };
        }

        fn splitValues(
            self: *Self,
            old_path: []const u8,
            old_value: []const u8,
            new_path: []const u8,
            new_value: []const u8,
        ) AllocUpdateError!*SparseNode {
            var branch = emptyBranch();
            if (old_path.len == 0) {
                branch.value = old_value;
            } else {
                branch.children[old_path[0]] = .{ .node = try self.newNode(.{ .leaf = .{
                    .path = old_path[1..],
                    .value = old_value,
                } }) };
            }
            if (new_path.len == 0) {
                branch.value = new_value;
            } else {
                branch.children[new_path[0]] = .{ .node = try self.newNode(.{ .leaf = .{
                    .path = new_path[1..],
                    .value = new_value,
                } }) };
            }
            return self.newNode(.{ .branch = branch });
        }

        fn delete(self: *Self, node: *SparseNode, key: []const u8) AllocUpdateError!void {
            var current = node;
            var remaining = key;
            var frames: std.ArrayList(WorkFrame) = .empty;
            defer frames.deinit(self.allocator);

            while (true) {
                try self.step();
                try self.materializeNode(current);
                switch (current.kind) {
                    .empty => return,
                    .hash => unreachable,
                    .leaf => |leaf| {
                        if (!std.mem.eql(u8, leaf.path, remaining)) return;
                        current.* = .{ .kind = .empty };
                        break;
                    },
                    .extension => |extension| {
                        if (!nibble.startsWith(remaining, extension.path)) return;
                        if (extension.child.kind == .hash) {
                            try self.materializeNode(extension.child);
                            if (extension.child.kind != .branch) return error.NonCanonicalNode;
                        }
                        try frames.append(self.allocator, .{ .delete = .{ .extension = current } });
                        current = extension.child;
                        remaining = remaining[extension.path.len..];
                    },
                    .branch => |*branch| {
                        if (remaining.len == 0) {
                            if (branch.value == null) return;
                            branch.value = null;
                            try self.compressBranch(current, branch.*);
                            break;
                        }
                        const child_index = remaining[0];
                        const child = (try self.branchChildNode(&branch.children[child_index])) orelse return;
                        try frames.append(self.allocator, .{ .delete = .{ .branch = .{
                            .parent = current,
                            .child_index = child_index,
                        } } });
                        current = child;
                        remaining = remaining[1..];
                    },
                }
            }

            while (frames.pop()) |work| {
                try self.step();
                switch (work.delete) {
                    .extension => |parent| {
                        const extension = switch (parent.kind) {
                            .extension => |value| value,
                            else => unreachable,
                        };
                        try self.compressExtension(parent, extension);
                    },
                    .branch => |frame| {
                        var branch = switch (frame.parent.kind) {
                            .branch => |value| value,
                            else => unreachable,
                        };
                        const child = switch (branch.children[frame.child_index]) {
                            .node => |value| value,
                            else => unreachable,
                        };
                        if (child.kind == .empty) branch.children[frame.child_index] = .empty;
                        try self.compressBranch(frame.parent, branch);
                    },
                }
            }
        }

        fn compressExtension(self: *Self, node: *SparseNode, extension: SparseNode.Extension) AllocUpdateError!void {
            switch (extension.child.kind) {
                .empty => node.* = .{ .kind = .empty },
                .hash, .branch => node.* = .{ .kind = .{ .extension = extension } },
                .leaf => |leaf| node.* = .{ .kind = .{ .leaf = .{
                    .path = try self.concat(extension.path, leaf.path),
                    .value = leaf.value,
                } } },
                .extension => |child_extension| node.* = .{ .kind = .{ .extension = .{
                    .path = try self.concat(extension.path, child_extension.path),
                    .child = child_extension.child,
                } } },
            }
        }

        fn compressBranch(self: *Self, node: *SparseNode, branch: SparseNode.Branch) AllocUpdateError!void {
            var child_count: usize = 0;
            var only_child_index: usize = 0;
            for (branch.children, 0..) |child, index| {
                if (child == .empty) continue;
                child_count += 1;
                only_child_index = index;
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

            const child = switch (branch.children[only_child_index]) {
                .empty => unreachable,
                .node => |value| value,
                .hash => |digest| try self.newNode(.{ .hash = digest.* }),
            };
            try self.materializeNode(child);
            const child_nibble: u8 = @intCast(only_child_index);
            switch (child.kind) {
                .empty => node.* = .{ .kind = .empty },
                .hash => unreachable,
                .branch => node.* = .{ .kind = .{ .extension = .{
                    .path = try self.oneNibble(child_nibble),
                    .child = child,
                } } },
                .leaf => |leaf| node.* = .{ .kind = .{ .leaf = .{
                    .path = try self.prepend(child_nibble, leaf.path),
                    .value = leaf.value,
                } } },
                .extension => |extension| node.* = .{ .kind = .{ .extension = .{
                    .path = try self.prepend(child_nibble, extension.path),
                    .child = extension.child,
                } } },
            }
        }

        fn encodeRoot(self: *Self, root: *SparseNode) AllocUpdateError!hash.Root {
            if (root.kind == .empty) return hash.empty_root;

            var frames: std.ArrayList(WorkFrame) = .empty;
            defer frames.deinit(self.allocator);
            var result: ?hash.Root = null;
            try frames.append(self.allocator, .{ .encode = .{
                .node = root,
                .expanded = false,
                .is_root = true,
            } });

            while (frames.pop()) |work| {
                const frame = work.encode;
                try self.step();

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
                        const lengths = try encode.leafBufferLengths(leaf.path, leaf.value);
                        const scratch = try self.buffers(lengths.compact, lengths.node);
                        const encoded = try encode.leaf(scratch.node, scratch.compact, leaf.path, leaf.value);
                        try self.finishEncoding(frame.node, encoded, frame.is_root, &result);
                        continue;
                    },
                    .extension => |extension| {
                        try frames.append(self.allocator, .{ .encode = .{
                            .node = frame.node,
                            .expanded = true,
                            .is_root = frame.is_root,
                        } });
                        try frames.append(self.allocator, .{ .encode = .{
                            .node = extension.child,
                            .expanded = false,
                            .is_root = false,
                        } });
                        continue;
                    },
                    .branch => |*branch| {
                        try frames.append(self.allocator, .{ .encode = .{
                            .node = frame.node,
                            .expanded = true,
                            .is_root = frame.is_root,
                        } });
                        var index: usize = branch.children.len;
                        while (index > 0) {
                            index -= 1;
                            switch (branch.children[index]) {
                                .node => |child| {
                                    try frames.append(self.allocator, .{ .encode = .{
                                        .node = child,
                                        .expanded = false,
                                        .is_root = false,
                                    } });
                                },
                                .empty, .hash => {},
                            }
                        }
                        continue;
                    },
                };

                const encoded = switch (frame.node.kind) {
                    .extension => |extension| encoded: {
                        const lengths = try encode.extensionBufferLengths(
                            extension.path,
                            &extension.child.reference,
                        );
                        const scratch = try self.buffers(lengths.compact, lengths.node);
                        break :encoded try encode.extension(
                            scratch.node,
                            scratch.compact,
                            extension.path,
                            &extension.child.reference,
                        );
                    },
                    .branch => |*branch| encoded: {
                        const node_len = try branchBufferLength(branch);
                        const scratch = try self.buffers(0, node_len);
                        break :encoded try encodeBranch(scratch.node, branch);
                    },
                    else => unreachable,
                };
                try self.finishEncoding(frame.node, encoded, frame.is_root, &result);
            }
            return result orelse error.InvalidNode;
        }

        fn finishEncoding(
            self: *Self,
            node: *SparseNode,
            encoded: []const u8,
            is_root: bool,
            result: *?hash.Root,
        ) AllocUpdateError!void {
            if (is_root) {
                result.* = self.keccak_context.keccak256(encoded);
            } else if (encoded.len < 32) {
                var embedded: Reference.Embedded = .{
                    .len = @intCast(encoded.len),
                    .bytes = undefined,
                };
                @memcpy(embedded.bytes[0..encoded.len], encoded);
                node.reference = .{ .embedded = embedded };
            } else {
                node.reference = .{ .hashed = self.keccak_context.keccak256(encoded) };
            }
        }

        fn keyNibbles(self: *Self, key: []const u8) AllocUpdateError![]u8 {
            const len = std.math.mul(usize, key.len, 2) catch return error.ResourceLimitExceeded;
            const out = try self.alloc(u8, len);
            for (out, 0..) |*value, index| value.* = nibble.keyNibbleAt(key, index);
            return out;
        }

        fn concat(self: *Self, lhs: []const u8, rhs: []const u8) AllocUpdateError![]u8 {
            const len = std.math.add(usize, lhs.len, rhs.len) catch return error.ResourceLimitExceeded;
            const out = try self.alloc(u8, len);
            @memcpy(out[0..lhs.len], lhs);
            @memcpy(out[lhs.len..], rhs);
            return out;
        }

        fn prepend(self: *Self, value: u8, rest: []const u8) AllocUpdateError![]u8 {
            const len = std.math.add(usize, rest.len, 1) catch return error.ResourceLimitExceeded;
            const out = try self.alloc(u8, len);
            out[0] = value;
            @memcpy(out[1..], rest);
            return out;
        }

        fn oneNibble(self: *Self, value: u8) AllocUpdateError![]u8 {
            const out = try self.alloc(u8, 1);
            out[0] = value;
            return out;
        }
    };
}

/// Apply `updates` (sorted ascending by key; a null value deletes the key) to
/// the trie rooted at `root_hash` within `index`, returning the new root.
/// Insertions run before deletions so a combined post-state update does not
/// require clean sibling nodes that the insertion makes unnecessary.
pub fn updateSorted(
    keccak_context: anytype,
    backing_allocator: Allocator,
    root_hash: hash.Root,
    index: *const proof.NodeIndex,
    updates: []const Update,
) AllocUpdateError!hash.Root {
    if (updates.len == 0) return root_hash;
    try validateUpdates(updates);

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
        break :root try context.decodeNode(encoded);
    };

    for (updates) |update| {
        const value = update.value orelse continue;
        const path = try context.keyNibbles(update.key);
        try context.insert(root_node, path, value);
    }
    for (updates) |update| {
        if (update.value != null) continue;
        const path = try context.keyNibbles(update.key);
        try context.delete(root_node, path);
    }

    return context.encodeRoot(root_node);
}

fn validateUpdates(updates: []const Update) errors.InputError!void {
    for (updates) |update| {
        if (update.value) |value| {
            if (value.len == 0) return error.EmptyValue;
        }
    }
    for (updates[1..], 1..) |update, index| {
        switch (std.mem.order(u8, updates[index - 1].key, update.key)) {
            .lt => {},
            .eq => return error.DuplicateKey,
            .gt => return error.UnsortedKeys,
        }
    }
}

fn branchBufferLength(branch: *const SparseNode.Branch) UpdateError!usize {
    var payload = try encode.bytesEncodedLen(branch.value orelse "");
    for (branch.children) |child| {
        const child_len = switch (child) {
            .empty => 1,
            .hash => 33,
            .node => |present| try encode.referenceEncodedLen(&present.reference),
        };
        payload = std.math.add(usize, payload, child_len) catch
            return error.ResourceLimitExceeded;
    }
    return encode.listEncodedLen(payload);
}

fn encodeBranch(node_buffer: []u8, branch: *const SparseNode.Branch) UpdateError![]const u8 {
    var payload_len = try encode.bytesEncodedLen(branch.value orelse "");
    for (branch.children) |child| {
        const child_len = switch (child) {
            .empty => 1,
            .hash => 33,
            .node => |present| try encode.referenceEncodedLen(&present.reference),
        };
        payload_len = std.math.add(usize, payload_len, child_len) catch
            return error.ResourceLimitExceeded;
    }
    var writer = try encode.listWriter(node_buffer, payload_len);
    for (branch.children) |child| {
        switch (child) {
            .empty => try encode.writeBytes(&writer, ""),
            .hash => |digest| try encode.writeReference(&writer, &.{ .hashed = digest.* }),
            .node => |present| try encode.writeReference(&writer, &present.reference),
        }
    }
    try encode.writeBytes(&writer, branch.value orelse "");
    return node_buffer[0 .. encode.listPrefixLen(payload_len) + writer.written().len];
}

fn emptyBranch() SparseNode.Branch {
    return .{ .children = [_]SparseNode.BranchChild{.empty} ** 16, .value = null };
}
