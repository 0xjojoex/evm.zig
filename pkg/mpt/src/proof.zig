//! Witness-backed proof lookup: index encoded nodes by hash, then walk the trie.

const std = @import("std");

const errors = @import("error.zig");
const IndexError = errors.IndexError;
const LookupError = errors.LookupError;
const InternalIndexError = IndexError || error{WorkspaceTooSmall};
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");
const node = @import("node.zig");

/// Why a key resolved to no value during a lookup.
pub const Absence = enum {
    empty_trie,
    missing_branch_child,
    empty_branch_value,
    divergent_path,
};

/// Result of a proof lookup: the stored value, or the reason it is absent.
pub const Lookup = union(enum) {
    present: []const u8,
    absent: Absence,
};

/// Lazily retains decoded authenticated nodes across proof lookups.
/// Decoded fields borrow from the witness bytes, which must outlive the cache.
pub const LookupCache = struct {
    allocator: std.mem.Allocator,
    index: ?*const NodeIndex = null,
    slots: []usize = &.{},
    entries: std.ArrayList(node.Node) = .empty,

    const empty_slot = std.math.maxInt(usize);

    pub fn init(allocator: std.mem.Allocator) LookupCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LookupCache) void {
        self.allocator.free(self.slots);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn decode(
        self: *LookupCache,
        index: *const NodeIndex,
        position: usize,
        encoded: []const u8,
        require_branch: bool,
    ) (std.mem.Allocator.Error || LookupError)!node.Node {
        try self.prepareIndex(index);
        const entry_index = self.slots[position];
        if (entry_index != empty_slot) {
            const decoded = self.entries.items[entry_index];
            if (require_branch and decoded != .branch) {
                return error.NonCanonicalNode;
            }
            return decoded;
        }

        const decoded = try node.decode(encoded, require_branch);
        try self.entries.append(self.allocator, decoded);
        self.slots[position] = self.entries.items.len - 1;
        return decoded;
    }

    fn prepareIndex(self: *LookupCache, index: *const NodeIndex) std.mem.Allocator.Error!void {
        if (self.index == index) return;

        const slots = try self.allocator.alloc(usize, nodeCount(index));
        @memset(slots, empty_slot);
        self.allocator.free(self.slots);
        self.slots = slots;
        self.entries.clearRetainingCapacity();
        self.index = index;
    }
};

pub const NodeRecord = struct {
    hash: hash.Root,
    encoded: []const u8,
};

pub const IndexStorage = struct {
    sealed: IndexData = .{},
};

/// Opaque authenticated witness-index capability. Safe code can only obtain a
/// pointer from an allocator-owned `IndexedNodes`; raw records cannot be
/// assembled into a value accepted by lookup or update operations.
pub const NodeIndex = opaque {};

const IndexData = struct {
    records: []const NodeRecord = &.{},

    /// The node whose hash equals `digest`, or null. Records must be sorted
    /// ascending by hash (as produced by `indexNodes`).
    pub fn find(self: IndexData, digest: hash.Root) ?IndexedNode {
        var low: usize = 0;
        var high = self.records.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, &self.records[mid].hash, &digest)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return .{ .encoded = self.records[mid].encoded, .position = mid },
            }
        }
        return null;
    }
};

const IndexedNode = struct {
    encoded: []const u8,
    position: usize,
};

/// Hash each node in `encoded_nodes` and build a sorted, deduplicated sealed
/// index in `storage`. Errors with `ConflictingNode` when two nodes share a hash
/// but differ in bytes.
pub fn indexNodes(
    keccak_context: anytype,
    index_storage: *IndexStorage,
    storage: []NodeRecord,
    encoded_nodes: []const []const u8,
) InternalIndexError!*const NodeIndex {
    if (storage.len < encoded_nodes.len) return error.WorkspaceTooSmall;

    for (encoded_nodes, 0..) |encoded, index| {
        storage[index] = .{ .hash = keccak_context.keccak256(encoded), .encoded = encoded };
    }

    const records = storage[0..encoded_nodes.len];
    std.sort.heap(NodeRecord, records, {}, recordLessThan);

    var unique_len: usize = 0;
    for (records) |record| {
        if (unique_len > 0 and std.mem.eql(u8, &records[unique_len - 1].hash, &record.hash)) {
            if (!std.mem.eql(u8, records[unique_len - 1].encoded, record.encoded)) {
                return error.ConflictingNode;
            }
            continue;
        }
        records[unique_len] = record;
        unique_len += 1;
    }
    index_storage.sealed = .{
        .records = records[0..unique_len],
    };
    return indexFromData(&index_storage.sealed);
}

pub fn emptyIndex(storage: *const IndexStorage) *const NodeIndex {
    return indexFromData(&storage.sealed);
}

pub fn nodeCount(index: *const NodeIndex) usize {
    return dataFromIndex(index).records.len;
}

pub fn find(index: *const NodeIndex, digest: hash.Root) ?[]const u8 {
    const indexed = dataFromIndex(index).find(digest) orelse return null;
    return indexed.encoded;
}

fn indexFromData(data: *const IndexData) *const NodeIndex {
    return @ptrCast(data);
}

fn dataFromIndex(index: *const NodeIndex) *const IndexData {
    return @ptrCast(@alignCast(index));
}

/// Walk the trie rooted at `root` within `index` to resolve `key`, following
/// hashed child references through the witness nodes.
pub fn lookup(root: hash.Root, index: *const NodeIndex, key: []const u8) LookupError!Lookup {
    return lookupWithCache(root, index, key, null) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
        else => |lookup_err| return lookup_err,
    };
}

pub fn lookupCached(
    root: hash.Root,
    index: *const NodeIndex,
    key: []const u8,
    cache: *LookupCache,
) (std.mem.Allocator.Error || LookupError)!Lookup {
    return lookupWithCache(root, index, key, cache);
}

fn lookupWithCache(
    root: hash.Root,
    index: *const NodeIndex,
    key: []const u8,
    cache: ?*LookupCache,
) (std.mem.Allocator.Error || LookupError)!Lookup {
    if (std.mem.eql(u8, &root, &hash.empty_root)) return .{ .absent = .empty_trie };
    const key_nibbles = std.math.mul(usize, key.len, 2) catch
        return error.ResourceLimitExceeded;
    const step_capacity = std.math.add(usize, key_nibbles, 1) catch
        return error.ResourceLimitExceeded;

    const root_node = dataFromIndex(index).find(root) orelse return error.MissingNode;
    var resolved = ResolvedReference{
        .encoded = root_node.encoded,
        .position = root_node.position,
    };
    var depth: usize = 0;
    var steps: usize = 0;
    var extension_parent = false;

    while (true) {
        steps = std.math.add(usize, steps, 1) catch return error.ResourceLimitExceeded;
        if (steps > step_capacity) return error.ResourceLimitExceeded;

        const decoded = if (cache) |active|
            if (resolved.position) |position|
                try active.decode(index, position, resolved.encoded, extension_parent)
            else
                try decodeForPath(resolved.encoded, extension_parent, key, depth)
        else
            try decodeForPath(resolved.encoded, extension_parent, key, depth);
        switch (decoded) {
            .leaf => |leaf| {
                const path = leaf.path;
                if (!path.matchesKey(key, depth)) return .{ .absent = .divergent_path };
                if (depth + path.len != nibble.keyNibbleLen(key)) {
                    return .{ .absent = .divergent_path };
                }
                return .{ .present = leaf.value };
            },
            .extension => |extension| {
                if (!extension.path.matchesKey(key, depth)) {
                    return .{ .absent = .divergent_path };
                }
                resolved = try resolveRequiredReference(index, extension.child);
                depth += extension.path.len;
                extension_parent = true;
            },
            .branch => |branch| {
                if (depth == nibble.keyNibbleLen(key)) {
                    return if (branch.value) |value|
                        .{ .present = value }
                    else
                        .{ .absent = .empty_branch_value };
                }
                if (depth > nibble.keyNibbleLen(key)) return error.InvalidNode;

                const selected = branch.children[nibble.keyNibbleAt(key, depth)];
                resolved = (try resolveReference(index, selected)) orelse
                    return .{ .absent = .missing_branch_child };
                depth += 1;
                extension_parent = false;
            },
        }
    }
}

fn decodeForPath(
    encoded: []const u8,
    require_branch: bool,
    key: []const u8,
    depth: usize,
) LookupError!node.Node {
    const selected: ?u4 = if (depth < nibble.keyNibbleLen(key))
        @intCast(nibble.keyNibbleAt(key, depth))
    else
        null;
    return node.decodeForLookup(encoded, require_branch, selected);
}

const ResolvedReference = struct {
    encoded: []const u8,
    position: ?usize,
};

fn resolveRequiredReference(index: *const NodeIndex, reference: node.Reference) LookupError!ResolvedReference {
    return (try resolveReference(index, reference)) orelse return error.InvalidNodeReference;
}

fn resolveReference(index: *const NodeIndex, reference: node.Reference) LookupError!?ResolvedReference {
    return switch (reference) {
        .empty => null,
        .embedded => |embedded| .{ .encoded = embedded, .position = null },
        .hashed => |digest| {
            const indexed = dataFromIndex(index).find(digest.*) orelse return error.MissingNode;
            if (indexed.encoded.len < 32) return error.InvalidNodeReference;
            return .{ .encoded = indexed.encoded, .position = indexed.position };
        },
    };
}

fn recordLessThan(_: void, lhs: NodeRecord, rhs: NodeRecord) bool {
    return std.mem.order(u8, &lhs.hash, &rhs.hash) == .lt;
}

test "decoded-node cache indexes many witness positions" {
    var cache = LookupCache.init(std.testing.allocator);
    defer cache.deinit();

    const node_count = 4_096;
    const records = try std.testing.allocator.alloc(NodeRecord, node_count);
    defer std.testing.allocator.free(records);
    const index_data = IndexData{ .records = records };
    const index = indexFromData(&index_data);
    const encoded_leaf = [_]u8{ 0xc2, 0x20, 0x01 };
    for (0..node_count) |position| {
        try std.testing.expect((try cache.decode(index, position, &encoded_leaf, false)) == .leaf);
    }
    try std.testing.expectEqual(@as(usize, node_count), cache.entries.items.len);

    for (0..node_count) |offset| {
        const position = node_count - offset - 1;
        try std.testing.expect((try cache.decode(index, position, &encoded_leaf, false)) == .leaf);
    }
    try std.testing.expectEqual(@as(usize, node_count), cache.entries.items.len);
}
