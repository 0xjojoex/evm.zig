//! Block-local mutation and commit over an authenticated witness catalog.
//!
//! The catalog is the immutable commitment topology. This module creates
//! mutable occurrences only for selected paths, keeps untouched children as
//! authenticated references, and recomputes one post-state root bottom-up.

const std = @import("std");
const RewindableRegion = @import("rewindable_region");

const catalog = @import("catalog.zig");
const encode = @import("encode.zig");
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

pub const Workspace = RewindableRegion;

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

        fn materialize(self: *Self, id: OccurrenceId) AllocUpdateError!void {
            const source_id = switch (self.occurrence(id).kind) {
                .source => |source| source,
                .sealed => return error.MissingNode,
                else => return,
            };
            const entry = self.catalog.node(source_id) orelse return error.InvalidNodeReference;
            switch (entry.kind) {
                .leaf => {
                    const path = entry.path() orelse return error.InvalidNode;
                    self.occurrence(id).kind = .{ .leaf = .{
                        .path = try self.copyCompactPath(path),
                        .value = entry.value() orelse return error.InvalidNode,
                    } };
                },
                .extension => {
                    const path = entry.path() orelse return error.InvalidNode;
                    const link = entry.extensionChild() orelse return error.InvalidNodeReference;
                    const reference = try self.catalog.extensionReference(source_id);
                    const child = try self.appendDeferred(
                        link,
                        reference,
                        .{ .extension = id },
                    );
                    self.occurrence(id).kind = .{ .extension = .{
                        .path = try self.copyCompactPath(path),
                        .child = child,
                    } };
                },
                .branch => {
                    const links = self.catalog.branchChildren(source_id) orelse
                        return error.InvalidNodeReference;
                    var branch = Occurrence.Branch.empty;
                    branch.source = source_id;
                    for (links, 0..) |link, child_index| {
                        if (link == .empty) continue;
                        branch.children[child_index] = .catalog;
                    }
                    branch.value = entry.value();
                    self.occurrence(id).kind = .{ .branch = branch };
                },
            }
        }

        fn appendDeferred(
            self: *Self,
            link: catalog.Link,
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
                else => if (link.node()) |id| self.newOccurrence(
                    .{ .source = id },
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
                .catalog => occurrence: {
                    const source = branch.source orelse return error.InvalidNodeReference;
                    const links = self.catalog.branchChildren(source) orelse
                        return error.InvalidNodeReference;
                    const reference = try self.catalog.branchReference(source, child_index);
                    const id = try self.appendDeferred(
                        links[child_index],
                        reference,
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

        fn copyCompactPath(self: *Self, path: nibble.CompactPath) AllocUpdateError![]u8 {
            const owned = try self.alloc(u8, path.len);
            for (owned, 0..) |*path_nibble, index| path_nibble.* = path.nibbleAt(index);
            return owned;
        }

        fn insert(
            self: *Self,
            root: OccurrenceId,
            key: []const u8,
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
                        try self.insertIntoLeaf(current, leaf, remaining, value);
                        return;
                    },
                    .extension => |extension| {
                        const common = nibble.commonPrefix(extension.path, remaining);
                        if (common != extension.path.len) {
                            try self.splitExtension(current, extension, remaining, value, common);
                            return;
                        }
                        current = extension.child;
                        remaining = remaining[common..];
                    },
                    .branch => |branch| {
                        if (remaining.len == 0) {
                            self.occurrence(current).kind.branch.value = value;
                            self.markDirty(current);
                            return;
                        }
                        const child_index = remaining[0];
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
                        _ = branch;
                        current = child;
                        remaining = remaining[1..];
                    },
                }
            }
        }

        fn insertIntoLeaf(
            self: *Self,
            node: OccurrenceId,
            leaf: Occurrence.Leaf,
            key: []const u8,
            value: []const u8,
        ) AllocUpdateError!void {
            const common = nibble.commonPrefix(leaf.path, key);
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
                    .path = key[0..common],
                    .child = branch,
                } };
                try self.populateSplitBranch(branch, leaf.path[common..], leaf.value, key[common..], value);
            }
            self.markDirty(node);
        }

        fn populateSplitBranch(
            self: *Self,
            branch_id: OccurrenceId,
            old_path: []const u8,
            old_value: []const u8,
            new_path: []const u8,
            new_value: []const u8,
        ) AllocUpdateError!void {
            if (old_path.len == 0) {
                self.occurrence(branch_id).kind.branch.value = old_value;
            } else {
                const leaf = try self.newLeaf(
                    old_path[1..],
                    old_value,
                    .{ .branch = .{ .node = branch_id, .child_index = old_path[0] } },
                );
                self.occurrence(branch_id).kind.branch.children[old_path[0]] = .{ .occurrence = leaf };
            }
            if (new_path.len == 0) {
                self.occurrence(branch_id).kind.branch.value = new_value;
            } else {
                const leaf = try self.newLeaf(
                    new_path[1..],
                    new_value,
                    .{ .branch = .{ .node = branch_id, .child_index = new_path[0] } },
                );
                self.occurrence(branch_id).kind.branch.children[new_path[0]] = .{ .occurrence = leaf };
            }
            self.markDirty(branch_id);
        }

        fn newLeaf(
            self: *Self,
            path: []const u8,
            value: []const u8,
            parent: Parent,
        ) Allocator.Error!OccurrenceId {
            return self.newOccurrence(.{ .leaf = .{ .path = path, .value = value } }, parent, .unset, true);
        }

        fn splitExtension(
            self: *Self,
            node: OccurrenceId,
            extension: Occurrence.Extension,
            key: []const u8,
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

            const old_remaining = extension.path[common..];
            const old_child = if (old_remaining.len == 1) extension.child else child: {
                const child = try self.newOccurrence(
                    .{ .extension = .{ .path = old_remaining[1..], .child = extension.child } },
                    .{ .branch = .{ .node = branch_id, .child_index = old_remaining[0] } },
                    .unset,
                    true,
                );
                self.setParent(extension.child, .{ .extension = child });
                break :child child;
            };
            self.setParent(old_child, .{ .branch = .{ .node = branch_id, .child_index = old_remaining[0] } });
            self.occurrence(branch_id).kind.branch.children[old_remaining[0]] = .{ .occurrence = old_child };

            const new_remaining = key[common..];
            if (new_remaining.len == 0) {
                self.occurrence(branch_id).kind.branch.value = value;
            } else {
                const leaf = try self.newLeaf(
                    new_remaining[1..],
                    value,
                    .{ .branch = .{ .node = branch_id, .child_index = new_remaining[0] } },
                );
                self.occurrence(branch_id).kind.branch.children[new_remaining[0]] = .{ .occurrence = leaf };
            }

            if (common != 0) {
                self.occurrence(node).kind = .{ .extension = .{
                    .path = key[0..common],
                    .child = branch_id,
                } };
            }
            self.markDirty(node);
        }

        fn delete(self: *Self, root: OccurrenceId, key: []const u8) AllocUpdateError!void {
            var current = root;
            var remaining = key;
            var frames: std.ArrayList(DeleteFrame) = .empty;
            defer frames.deinit(self.allocator);

            while (true) {
                try self.materialize(current);
                const kind = self.occurrence(current).kind;
                switch (kind) {
                    .empty => return,
                    .sealed, .source => unreachable,
                    .leaf => |leaf| {
                        if (!std.mem.eql(u8, leaf.path, remaining)) return;
                        self.occurrence(current).kind = .empty;
                        self.occurrence(current).reference = .empty;
                        self.markDirty(current);
                        break;
                    },
                    .extension => |extension| {
                        if (!nibble.startsWith(remaining, extension.path)) return;
                        try frames.append(self.allocator, .{ .extension = current });
                        current = extension.child;
                        remaining = remaining[extension.path.len..];
                    },
                    .branch => |branch| {
                        if (remaining.len == 0) {
                            if (branch.value == null) return;
                            self.occurrence(current).kind.branch.value = null;
                            self.markDirty(current);
                            try self.compressBranch(current);
                            break;
                        }
                        const child_index = remaining[0];
                        const child = (try self.childOccurrence(current, child_index)) orelse return;
                        try frames.append(self.allocator, .{ .branch = .{
                            .node = current,
                            .child_index = child_index,
                        } });
                        current = child;
                        remaining = remaining[1..];
                    },
                }
            }

            while (frames.pop()) |frame| switch (frame) {
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
            };
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

            if (branch.value) |value| {
                if (child_count == 0) {
                    self.occurrence(node).kind = .{ .leaf = .{ .path = &.{}, .value = value } };
                }
                self.markDirty(node);
                return;
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
                        const lengths = try encode.leafBufferLengths(leaf.path, leaf.value);
                        const scratch = try self.buffers(lengths.compact, lengths.node);
                        const encoded = try encode.leaf(scratch.node, scratch.compact, leaf.path, leaf.value);
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
                                .empty, .catalog => {},
                            }
                        }
                        continue;
                    },
                };

                const encoded = switch (node.kind) {
                    .extension => |extension| encoded: {
                        const reference = &self.occurrence(extension.child).reference;
                        const lengths = try encode.extensionBufferLengths(extension.path, reference);
                        const scratch = try self.buffers(lengths.compact, lengths.node);
                        break :encoded try encode.extension(
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
                result.* = self.keccak_context.keccak256(encoded);
            } else if (encoded.len < 32) {
                var embedded: Reference.Embedded = .{
                    .len = @intCast(encoded.len),
                    .bytes = undefined,
                };
                @memcpy(embedded.bytes[0..encoded.len], encoded);
                self.occurrence(node).reference = .{ .embedded = embedded };
            } else {
                self.occurrence(node).reference = .{ .hashed = self.keccak_context.keccak256(encoded) };
            }
        }

        fn branchBufferLengths(self: *Self, branch: *const Occurrence.Branch) UpdateError!BranchBufferLengths {
            var payload = try encode.bytesEncodedLen(branch.value orelse "");
            for (&branch.children, 0..) |*child, index| {
                const child_len = switch (child.*) {
                    .empty => 1,
                    .catalog => try self.catalog.branchReferenceEncodedLen(
                        branch.source orelse return error.InvalidNodeReference,
                        index,
                    ),
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
        ) UpdateError![]const u8 {
            var writer = try encode.listWriter(node_buffer, payload_len);
            for (&branch.children, 0..) |*child, index| switch (child.*) {
                .empty => try encode.writeBytes(&writer, ""),
                .catalog => try encode.writeCodecReference(
                    &writer,
                    try self.catalog.branchReference(
                        branch.source orelse return error.InvalidNodeReference,
                        index,
                    ),
                ),
                .occurrence => |id| try encode.writeReference(&writer, &self.occurrence(id).reference),
            };
            try encode.writeBytes(&writer, branch.value orelse "");
            return node_buffer[0 .. encode.listPrefixLen(payload_len) + writer.written().len];
        }

        fn keyNibbles(self: *Self, key: hash.Root) AllocUpdateError![]u8 {
            const out = try self.alloc(u8, 64);
            for (out, 0..) |*value, index| value.* = nibble.keyNibbleAt(&key, index);
            return out;
        }

        fn concat(self: *Self, lhs: []const u8, rhs: []const u8) AllocUpdateError![]u8 {
            const len = std.math.add(usize, lhs.len, rhs.len) catch return error.ResourceLimitExceeded;
            const out = try self.alloc(u8, len);
            @memcpy(out[0..lhs.len], lhs);
            @memcpy(out[lhs.len..], rhs);
            return out;
        }

        fn prepend(self: *Self, first: u8, tail: []const u8) AllocUpdateError![]u8 {
            const out = try self.alloc(u8, std.math.add(usize, 1, tail.len) catch
                return error.ResourceLimitExceeded);
            out[0] = first;
            @memcpy(out[1..], tail);
            return out;
        }

        fn oneNibble(self: *Self, value: u8) Allocator.Error![]u8 {
            const out = try self.alloc(u8, 1);
            out[0] = value;
            return out;
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

    const mark = workspace.mark();
    defer workspace.rewind(mark);
    const allocator = workspace.allocator();
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
        const path = try context.keyNibbles(update.key);
        try context.insert(root, path, value);
    }
    for (updates) |update| {
        if (update.value != null) continue;
        const path = try context.keyNibbles(update.key);
        try context.delete(root, path);
    }

    if (!context.occurrence(root).dirty) return root_hash;
    return context.encodeRoot(root);
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

const BranchBufferLengths = struct {
    payload: usize,
    node: usize,
};
