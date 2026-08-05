//! Immutable authenticated topology linked from a sealed witness index.
//!
//! Ingest resolves witness-present hashes once. Missing hashed children remain
//! opaque authenticated references; embedded children are always decoded and
//! linked. The sealed catalog serves lookups without hashing, index search,
//! allocation, or RLP decoding.

const std = @import("std");

const errors = @import("error.zig");
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");
const node_codec = @import("node.zig");
const proof = @import("proof.zig");

pub const BuildError = std.mem.Allocator.Error || errors.LookupError;
pub const InitError = std.mem.Allocator.Error || error{ResourceLimitExceeded};

pub const Limits = struct {
    indexed_nodes: usize = std.math.maxInt(usize),
    linked_nodes: usize = std.math.maxInt(usize),
    branches: usize = std.math.maxInt(usize),
};

pub const NodeId = enum(u32) { _ };

pub const AuthenticatedRoot = struct {
    id: NodeId,
    digest: hash.Root,
};

pub const RootRef = union(enum) {
    empty,
    node: AuthenticatedRoot,
};

pub const BoundValue = struct {
    node: NodeId,
    value: []const u8,
};

pub const BoundLookup = union(enum) {
    present: BoundValue,
    absent: proof.Absence,
};

/// Compact traversal edge. Opaque links retain their digest in the original
/// encoded parent and intentionally cannot be followed by the catalog reader.
pub const Link = enum(u32) {
    empty = std.math.maxInt(u32),
    @"opaque" = std.math.maxInt(u32) - 1,
    _,

    fn fromNode(id: NodeId) Link {
        return @enumFromInt(@intFromEnum(id));
    }

    pub fn node(self: Link) ?NodeId {
        const raw = @intFromEnum(self);
        if (raw >= @intFromEnum(Link.@"opaque")) return null;
        return @enumFromInt(raw);
    }
};

pub const Node = struct {
    encoded: []const u8,
    payload: u32,
    path_offset: u16,
    path_byte_len: u16,
    path_nibble_len: u16,
    value_offset: u16,
    value_len: u16,
    path_nibble_offset: u8,
    kind: Kind,

    pub const Kind = enum(u8) {
        leaf,
        extension,
        branch,
    };

    pub fn path(self: Node) ?nibble.CompactPath {
        if (self.kind == .branch) return null;
        const start = self.path_offset;
        return .{
            .encoded = self.encoded[start .. start + self.path_byte_len],
            .nibble_offset = self.path_nibble_offset,
            .len = self.path_nibble_len,
            .terminal = self.kind == .leaf,
        };
    }

    pub fn value(self: Node) ?[]const u8 {
        if (self.value_len == 0) return null;
        const start = self.value_offset;
        return self.encoded[start .. start + self.value_len];
    }

    pub fn extensionChild(self: Node) ?Link {
        if (self.kind != .extension) return null;
        return @enumFromInt(self.payload);
    }
};

pub const BranchLinks = [16]Link;

/// Compact branch topology plus offsets of hashed references in the original
/// encoded parent. Embedded children borrow their encoding from the linked
/// child descriptor; empty references do not use an offset.
pub const Branch = struct {
    links: BranchLinks,
    reference_offsets: [16]u16,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    branches: std.ArrayList(Branch),

    pub fn deinit(self: *Catalog) void {
        self.nodes.deinit(self.allocator);
        self.branches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn nodeCount(self: Catalog) usize {
        return self.nodes.items.len;
    }

    pub fn nodeCapacity(self: Catalog) usize {
        return self.nodes.capacity;
    }

    pub fn node(self: Catalog, id: NodeId) ?*const Node {
        const index = @intFromEnum(id);
        if (index >= self.nodes.items.len) return null;
        return &self.nodes.items[index];
    }

    pub fn branchCount(self: Catalog) usize {
        return self.branches.items.len;
    }

    pub fn branchCapacity(self: Catalog) usize {
        return self.branches.capacity;
    }

    pub fn branchChildren(self: Catalog, id: NodeId) ?*const BranchLinks {
        const entry = self.node(id) orelse return null;
        if (entry.kind != .branch or entry.payload >= self.branches.items.len) return null;
        return &self.branches.items[entry.payload].links;
    }

    pub fn extensionReference(self: Catalog, id: NodeId) errors.LookupError!node_codec.Reference {
        const entry = self.node(id) orelse return error.InvalidNodeReference;
        const link = entry.extensionChild() orelse return error.InvalidNodeReference;
        return self.reference(entry, link, entry.value_offset);
    }

    pub fn branchReference(
        self: Catalog,
        id: NodeId,
        child_index: usize,
    ) errors.LookupError!node_codec.Reference {
        if (child_index >= 16) return error.InvalidNodeReference;
        const entry = self.node(id) orelse return error.InvalidNodeReference;
        if (entry.kind != .branch or entry.payload >= self.branches.items.len) {
            return error.InvalidNodeReference;
        }
        const branch = &self.branches.items[entry.payload];
        return self.reference(entry, branch.links[child_index], branch.reference_offsets[child_index]);
    }

    pub fn branchReferenceEncodedLen(
        self: Catalog,
        id: NodeId,
        child_index: usize,
    ) errors.LookupError!usize {
        if (child_index >= 16) return error.InvalidNodeReference;
        const entry = self.node(id) orelse return error.InvalidNodeReference;
        if (entry.kind != .branch or entry.payload >= self.branches.items.len) {
            return error.InvalidNodeReference;
        }
        const link = self.branches.items[entry.payload].links[child_index];
        return switch (link) {
            .empty => 1,
            .@"opaque" => 33,
            _ => if (link.node()) |child_id| child: {
                const child_node = self.node(child_id) orelse return error.InvalidNodeReference;
                break :child if (child_node.encoded.len < 32) child_node.encoded.len else 33;
            } else error.InvalidNodeReference,
        };
    }

    fn reference(
        self: Catalog,
        parent: *const Node,
        link: Link,
        offset: u16,
    ) errors.LookupError!node_codec.Reference {
        return switch (link) {
            .empty => .empty,
            .@"opaque" => .{ .hashed = try hashedReference(parent.encoded, offset) },
            _ => if (link.node()) |id| linked: {
                const child = self.node(id) orelse return error.InvalidNodeReference;
                if (child.encoded.len < 32) break :linked .{ .embedded = child.encoded };
                break :linked .{ .hashed = try hashedReference(parent.encoded, offset) };
            } else error.InvalidNodeReference,
        };
    }

    pub fn lookup(self: Catalog, root: RootRef, key: []const u8) errors.LookupError!proof.Lookup {
        return switch (try self.lookupBound(root, key)) {
            .present => |present| .{ .present = present.value },
            .absent => |absence| .{ .absent = absence },
        };
    }

    /// Lookup plus the stable terminal node handle used to bind typed values.
    pub fn lookupBound(self: Catalog, root: RootRef, key: []const u8) errors.LookupError!BoundLookup {
        if (root == .empty) return .{ .absent = .empty_trie };
        const key_nibbles = std.math.mul(usize, key.len, 2) catch
            return error.ResourceLimitExceeded;
        const step_capacity = std.math.add(usize, key_nibbles, 1) catch
            return error.ResourceLimitExceeded;

        var current = root.node.id;
        var depth: usize = 0;
        var steps: usize = 0;
        while (true) {
            steps = std.math.add(usize, steps, 1) catch return error.ResourceLimitExceeded;
            if (steps > step_capacity) return error.ResourceLimitExceeded;

            const current_node = self.node(current) orelse return error.InvalidNodeReference;
            switch (current_node.kind) {
                .leaf => {
                    const path = current_node.path() orelse return error.InvalidNode;
                    if (!path.matchesKey(key, depth)) return .{ .absent = .divergent_path };
                    if (depth + path.len != key_nibbles) return .{ .absent = .divergent_path };
                    return .{ .present = .{
                        .node = current,
                        .value = current_node.value() orelse return error.InvalidNode,
                    } };
                },
                .extension => {
                    const path = current_node.path() orelse return error.InvalidNode;
                    if (!path.matchesKey(key, depth)) return .{ .absent = .divergent_path };
                    current = try followRequired(current_node.extensionChild() orelse return error.InvalidNodeReference);
                    depth += path.len;
                },
                .branch => {
                    if (depth == key_nibbles) {
                        return if (current_node.value()) |value|
                            .{ .present = .{ .node = current, .value = value } }
                        else
                            .{ .absent = .empty_branch_value };
                    }
                    if (depth > key_nibbles) return error.InvalidNode;
                    const children = self.branchChildren(current) orelse return error.InvalidNodeReference;
                    const selected = children[nibble.keyNibbleAt(key, depth)];
                    current = (try follow(selected)) orelse
                        return .{ .absent = .missing_branch_child };
                    depth += 1;
                },
            }
        }
    }

    fn followRequired(link: Link) errors.LookupError!NodeId {
        return (try follow(link)) orelse return error.InvalidNodeReference;
    }

    fn follow(link: Link) errors.LookupError!?NodeId {
        return switch (link) {
            .empty => null,
            .@"opaque" => error.MissingNode,
            _ => link.node() orelse error.InvalidNodeReference,
        };
    }
};

/// Ingestion-only owner. Node IDs returned by `authenticateRoot` remain stable
/// after further roots are added and after `finish` seals the catalog.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    index: *const proof.NodeIndex,
    positions: []u32,
    nodes: std.ArrayList(Node) = .empty,
    branches: std.ArrayList(Branch) = .empty,
    states: std.ArrayList(u32) = .empty,
    work: std.ArrayList(NodeId) = .empty,
    limits: Limits,
    sealed: bool = false,

    const no_node = std.math.maxInt(u32);
    const pending: u32 = 0;
    const decoded: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, index: *const proof.NodeIndex) std.mem.Allocator.Error!Builder {
        return initWithLimits(allocator, index, .{}) catch |err| switch (err) {
            error.ResourceLimitExceeded => unreachable,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        index: *const proof.NodeIndex,
        limits: Limits,
    ) InitError!Builder {
        if (proof.nodeCount(index) > limits.indexed_nodes) return error.ResourceLimitExceeded;
        const positions = try allocator.alloc(u32, proof.nodeCount(index));
        @memset(positions, no_node);
        return .{ .allocator = allocator, .index = index, .positions = positions, .limits = limits };
    }

    pub fn deinit(self: *Builder) void {
        self.allocator.free(self.positions);
        self.nodes.deinit(self.allocator);
        self.branches.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.work.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn authenticateRoot(self: *Builder, digest: hash.Root) BuildError!RootRef {
        std.debug.assert(!self.sealed);
        if (std.mem.eql(u8, &digest, &hash.empty_root)) return .empty;
        const indexed = proof.findIndexed(self.index, digest) orelse return error.MissingNode;
        const id = try self.linkIndexed(indexed);
        try self.decodePending();
        return .{ .node = .{ .id = id, .digest = digest } };
    }

    /// Inspect authenticated nodes between root additions. Returned descriptors
    /// are copies because adding another root may reallocate builder storage.
    pub fn nodeCount(self: *const Builder) usize {
        std.debug.assert(!self.sealed and self.work.items.len == 0);
        return self.nodes.items.len;
    }

    pub fn node(self: *const Builder, id: NodeId) ?Node {
        std.debug.assert(!self.sealed and self.work.items.len == 0);
        const index = @intFromEnum(id);
        if (index >= self.nodes.items.len or self.states.items[index] != decoded) return null;
        return self.nodes.items[index];
    }

    pub fn finish(self: *Builder) BuildError!Catalog {
        std.debug.assert(!self.sealed);
        try self.decodePending();
        try self.validateLocalTopology();
        try self.validateAcyclic();
        return self.takeCatalog();
    }

    /// Seal topology derived from a collision-resistant content hash without
    /// re-proving acyclicity. Embedded references are finite by construction;
    /// a hashed cycle requires a digest fixed point or collision. Local link
    /// bounds and canonical extension shape remain fully validated.
    pub fn finishAssumeCollisionResistant(self: *Builder) BuildError!Catalog {
        std.debug.assert(!self.sealed);
        try self.decodePending();
        try self.validateLocalTopology();
        return self.takeCatalog();
    }

    fn takeCatalog(self: *Builder) Catalog {
        self.sealed = true;
        const nodes = self.nodes;
        self.nodes = .empty;
        const branches = self.branches;
        self.branches = .empty;
        self.allocator.free(self.positions);
        self.positions = &.{};
        self.states.deinit(self.allocator);
        self.states = .empty;
        self.work.deinit(self.allocator);
        self.work = .empty;
        return .{ .allocator = self.allocator, .nodes = nodes, .branches = branches };
    }

    fn decodePending(self: *Builder) BuildError!void {
        while (self.work.pop()) |id| {
            const index = @intFromEnum(id);
            if (self.states.items[index] == decoded) continue;
            var decoded_node = try node_codec.decodeForCatalog(self.nodes.items[index].encoded);
            const compact = try self.compactNode(self.nodes.items[index].encoded, &decoded_node);
            self.nodes.items[index] = compact;
            self.states.items[index] = decoded;
        }
    }

    fn linkChildren(
        self: *Builder,
        encoded: []const u8,
        references: *const [16]node_codec.CatalogReference,
    ) BuildError!u32 {
        if (self.branches.items.len >= self.limits.branches) return error.ResourceLimitExceeded;
        var branch: Branch = undefined;
        for (references, 0..) |compact_reference, index| {
            const reference = compact_reference.reference(encoded);
            switch (reference) {
                .empty => {
                    branch.links[index] = .empty;
                    branch.reference_offsets[index] = 0;
                },
                else => {
                    branch.links[index] = try self.linkReference(reference);
                    branch.reference_offsets[index] = @intCast(compact_reference.offset);
                },
            }
        }
        if (self.branches.items.len > std.math.maxInt(u32)) return error.ResourceLimitExceeded;
        const index: u32 = @intCast(self.branches.items.len);
        try self.branches.append(self.allocator, branch);
        return index;
    }

    fn linkReference(self: *Builder, reference: node_codec.Reference) BuildError!Link {
        return switch (reference) {
            .empty => .empty,
            .embedded => |encoded| Link.fromNode(try self.appendNode(encoded)),
            .hashed => |digest| if (proof.findIndexed(self.index, digest.*)) |indexed|
                if (indexed.encoded.len < 32)
                    error.InvalidNodeReference
                else
                    Link.fromNode(try self.linkIndexed(indexed))
            else
                .@"opaque",
        };
    }

    fn linkIndexed(self: *Builder, indexed: proof.IndexedNode) BuildError!NodeId {
        if (self.positions[indexed.position] != no_node) {
            return @enumFromInt(self.positions[indexed.position]);
        }
        const id = try self.appendNode(indexed.encoded);
        self.positions[indexed.position] = @intFromEnum(id);
        return id;
    }

    fn appendNode(self: *Builder, encoded: []const u8) BuildError!NodeId {
        if (self.nodes.items.len >= self.limits.linked_nodes) return error.ResourceLimitExceeded;
        if (self.nodes.items.len >= @intFromEnum(Link.@"opaque")) return error.ResourceLimitExceeded;
        const id: NodeId = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
        try self.nodes.append(self.allocator, .{
            .encoded = encoded,
            .payload = undefined,
            .path_offset = undefined,
            .path_byte_len = undefined,
            .path_nibble_len = undefined,
            .value_offset = undefined,
            .value_len = undefined,
            .path_nibble_offset = undefined,
            .kind = undefined,
        });
        errdefer _ = self.nodes.pop();
        try self.states.append(self.allocator, pending);
        errdefer _ = self.states.pop();
        try self.work.append(self.allocator, id);
        return id;
    }

    fn compactNode(self: *Builder, encoded: []const u8, decoded_node: *node_codec.CatalogNode) BuildError!Node {
        if (encoded.len > std.math.maxInt(u16)) return error.ResourceLimitExceeded;
        var compact: Node = .{
            .encoded = encoded,
            .payload = 0,
            .path_offset = 0,
            .path_byte_len = 0,
            .path_nibble_len = 0,
            .value_offset = 0,
            .value_len = 0,
            .path_nibble_offset = 0,
            .kind = undefined,
        };
        switch (decoded_node.*) {
            .leaf => |leaf| {
                try setPath(&compact, leaf.path);
                try setValue(&compact, leaf.value);
                compact.kind = .leaf;
            },
            .extension => |extension| {
                try setPath(&compact, extension.path);
                compact.payload = @intFromEnum(try self.linkReference(extension.child));
                compact.value_offset = try referenceOffset(encoded, extension.child);
                compact.kind = .extension;
            },
            .branch => |*branch| {
                compact.payload = try self.linkChildren(encoded, &branch.children);
                if (branch.value) |value| try setValue(&compact, value);
                compact.kind = .branch;
            },
        }
        return compact;
    }

    fn setPath(compact: *Node, path: nibble.CompactPath) BuildError!void {
        const span = try compactSpan(compact.encoded, path.encoded);
        if (path.len > std.math.maxInt(u16) or path.nibble_offset > std.math.maxInt(u8)) {
            return error.ResourceLimitExceeded;
        }
        compact.path_offset = span.offset;
        compact.path_byte_len = span.len;
        compact.path_nibble_len = @intCast(path.len);
        compact.path_nibble_offset = @intCast(path.nibble_offset);
    }

    fn setValue(compact: *Node, value: []const u8) BuildError!void {
        const span = try compactSpan(compact.encoded, value);
        compact.value_offset = span.offset;
        compact.value_len = span.len;
    }

    const CompactSpan = struct {
        offset: u16,
        len: u16,
    };

    fn compactSpan(encoded: []const u8, span: []const u8) BuildError!CompactSpan {
        if (span.len > std.math.maxInt(u16)) return error.ResourceLimitExceeded;
        const base = @intFromPtr(encoded.ptr);
        const start = @intFromPtr(span.ptr);
        if (start < base) return error.InvalidNode;
        const offset = start - base;
        if (offset > encoded.len or span.len > encoded.len - offset) return error.InvalidNode;
        if (offset > std.math.maxInt(u16)) return error.ResourceLimitExceeded;
        return .{ .offset = @intCast(offset), .len = @intCast(span.len) };
    }

    fn referenceOffset(encoded: []const u8, reference: node_codec.Reference) BuildError!u16 {
        const span = switch (reference) {
            .empty => return 0,
            .embedded => |child| child,
            .hashed => |digest| digest,
        };
        return (try compactSpan(encoded, span)).offset;
    }

    fn validateLocalTopology(self: *Builder) BuildError!void {
        for (self.nodes.items) |entry| {
            switch (entry.kind) {
                .leaf => {},
                .extension => {
                    if ((entry.extensionChild() orelse return error.InvalidNodeReference).node()) |child| {
                        if (@intFromEnum(child) >= self.nodes.items.len) return error.InvalidNodeReference;
                        const target = self.nodes.items[@intFromEnum(child)];
                        if (target.kind != .branch) return error.NonCanonicalNode;
                    }
                },
                .branch => for ((try self.branchData(entry)).links) |child| {
                    if (child.node()) |id| {
                        if (@intFromEnum(id) >= self.nodes.items.len) return error.InvalidNodeReference;
                    }
                },
            }
        }
    }

    fn validateAcyclic(self: *Builder) BuildError!void {
        @memset(self.states.items, 0);
        for (self.nodes.items) |entry| switch (entry.kind) {
            .leaf => {},
            .extension => {
                if ((entry.extensionChild() orelse return error.InvalidNodeReference).node()) |child| {
                    try addIncoming(self.states.items, child);
                }
            },
            .branch => for ((try self.branchData(entry)).links) |child| {
                if (child.node()) |id| try addIncoming(self.states.items, id);
            },
        };

        self.work.clearRetainingCapacity();
        for (self.states.items, 0..) |incoming, index| {
            if (incoming == 0) try self.work.append(self.allocator, @enumFromInt(@as(u32, @intCast(index))));
        }

        var visited: usize = 0;
        var queue_index: usize = 0;
        while (queue_index < self.work.items.len) : (queue_index += 1) {
            const id = self.work.items[queue_index];
            visited += 1;
            const entry = self.nodes.items[@intFromEnum(id)];
            switch (entry.kind) {
                .leaf => {},
                .extension => try self.removeIncoming(entry.extensionChild() orelse return error.InvalidNodeReference),
                .branch => for ((try self.branchData(entry)).links) |child| try self.removeIncoming(child),
            }
        }
        if (visited != self.nodes.items.len) return error.InvalidNodeReference;
    }

    fn branchData(self: *Builder, entry: Node) errors.LookupError!*const Branch {
        if (entry.kind != .branch or entry.payload >= self.branches.items.len) return error.InvalidNodeReference;
        return &self.branches.items[entry.payload];
    }

    fn removeIncoming(self: *Builder, link: Link) BuildError!void {
        const id = link.node() orelse return;
        const index = @intFromEnum(id);
        if (self.states.items[index] == 0) return error.InvalidNodeReference;
        self.states.items[index] -= 1;
        if (self.states.items[index] == 0) try self.work.append(self.allocator, id);
    }

    fn addIncoming(incoming: []u32, id: NodeId) error{ResourceLimitExceeded}!void {
        const value = &incoming[@intFromEnum(id)];
        value.* = std.math.add(u32, value.*, 1) catch return error.ResourceLimitExceeded;
    }
};

fn hashedReference(encoded: []const u8, offset: u16) errors.LookupError!node_codec.HashedReference {
    const start: usize = offset;
    if (start > encoded.len or encoded.len - start < @sizeOf(hash.Root)) {
        return error.InvalidNodeReference;
    }
    return @ptrCast(encoded[start..][0..@sizeOf(hash.Root)].ptr);
}

test "compact catalog spans reject unrepresentable lengths" {
    const encoded = try std.testing.allocator.alloc(u8, std.math.maxInt(u16) + 1);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.ResourceLimitExceeded,
        Builder.compactSpan(encoded, encoded),
    );
}
