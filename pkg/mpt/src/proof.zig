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

/// Node digest as native-endian words. A `[32]u8` digest in a heap record is
/// align-1 and would compare through byte ladders on targets without
/// unaligned loads; word keys compare in registers and keep the record
/// word-aligned. Word 0 also serves as the position-table hash.
const NodeKey = [4]u64;

fn nodeKey(digest: hash.Root) NodeKey {
    return @bitCast(digest);
}

fn keyEquals(lhs: NodeKey, rhs: NodeKey) bool {
    inline for (lhs, rhs) |left, right| {
        if (left != right) return false;
    }
    return true;
}

inline fn borrowedKeyWord(digest: *align(1) const hash.Root, comptime index: usize) u64 {
    const bytes: [*]align(1) const u8 = @ptrCast(digest);
    const word: *align(1) const [@sizeOf(u64)]u8 = @ptrCast(bytes + index * @sizeOf(u64));
    return @bitCast(word.*);
}

/// Keep align-1 tail assembly behind word-zero equality on RV64 guests.
noinline fn borrowedKeyTailEquals(key: *const NodeKey, digest: *align(1) const hash.Root) bool {
    inline for (1..4) |index| {
        if (key[index] != borrowedKeyWord(digest, index)) return false;
    }
    return true;
}

pub const NodeRecord = struct {
    key: NodeKey,
    encoded: []const u8,
};

pub const IndexStorage = struct {
    sealed: IndexData = .{},
};

/// Opaque authenticated witness-index capability. Safe code can only obtain a
/// pointer from an allocator-owned `IndexedNodes`; raw records cannot be
/// assembled into a value accepted by lookup or update operations.
pub const NodeIndex = opaque {};

/// Table capacity for `node_count` records: a power of two with at most 50%
/// load, so probe chains stay short and the mask is one AND.
pub fn tableCapacity(node_count: usize) usize {
    if (node_count == 0) return 0;
    return std.math.ceilPowerOfTwo(usize, node_count * 2) catch unreachable;
}

const IndexData = struct {
    records: []const NodeRecord = &.{},
    /// Open-addressing position table: record position + 1, 0 = empty slot.
    /// Slots are addressed by digest word 0 — keccak output is uniform, so no
    /// second hash is needed. Length is a power of two (`tableCapacity`).
    table: []const u32 = &.{},

    /// The node whose hash equals `digest`, or null.
    pub fn find(self: IndexData, digest: hash.Root) ?IndexedNode {
        if (self.table.len == 0) return null;
        const key = nodeKey(digest);
        const mask: u64 = self.table.len - 1;
        var slot: usize = @intCast(key[0] & mask);
        while (true) {
            const entry = self.table[slot];
            if (entry == 0) return null;
            const record = &self.records[entry - 1];
            if (keyEquals(record.key, key)) {
                return .{ .encoded = record.encoded, .position = entry - 1 };
            }
            slot = @intCast((slot + 1) & mask);
        }
    }

    /// Probe a digest borrowed from an encoded node without first assembling
    /// its full align-1 byte representation into an aligned value.
    fn findBorrowed(self: IndexData, digest: *align(1) const hash.Root) ?IndexedNode {
        if (self.table.len == 0) return null;
        const word_0 = borrowedKeyWord(digest, 0);
        const mask: u64 = self.table.len - 1;
        var slot: usize = @intCast(word_0 & mask);
        while (true) {
            const entry = self.table[slot];
            if (entry == 0) return null;
            const record = &self.records[entry - 1];
            if (record.key[0] == word_0 and borrowedKeyTailEquals(&record.key, digest)) {
                return .{ .encoded = record.encoded, .position = entry - 1 };
            }
            slot = @intCast((slot + 1) & mask);
        }
    }
};

pub const IndexedNode = struct {
    encoded: []const u8,
    position: usize,
};

/// Hash each node in `encoded_nodes` and build a deduplicated sealed index in
/// `storage` with a hashed position `table` (sized by `tableCapacity`).
/// Records keep first-occurrence order, so positions are dense and stable.
/// Errors with `ConflictingNode` when two nodes share a hash but differ in
/// bytes.
pub fn indexNodes(
    keccak_context: anytype,
    index_storage: *IndexStorage,
    storage: []NodeRecord,
    table: []u32,
    encoded_nodes: []const []const u8,
) InternalIndexError!*const NodeIndex {
    if (storage.len < encoded_nodes.len) return error.WorkspaceTooSmall;
    const capacity = tableCapacity(encoded_nodes.len);
    if (table.len < capacity) return error.WorkspaceTooSmall;
    // Position entries are u32; a witness cannot hold 4G nodes.
    std.debug.assert(encoded_nodes.len < std.math.maxInt(u32));

    const active_table = table[0..capacity];
    @memset(active_table, 0);
    const mask: u64 = capacity -% 1;
    var unique_len: usize = 0;
    for (encoded_nodes) |encoded| {
        const key = nodeKey(keccak_context.keccak256(encoded));
        var slot: usize = @intCast(key[0] & mask);
        while (true) {
            const entry = active_table[slot];
            if (entry == 0) {
                storage[unique_len] = .{ .key = key, .encoded = encoded };
                active_table[slot] = @intCast(unique_len + 1);
                unique_len += 1;
                break;
            }
            const record = &storage[entry - 1];
            if (keyEquals(record.key, key)) {
                if (!std.mem.eql(u8, record.encoded, encoded)) return error.ConflictingNode;
                break;
            }
            slot = @intCast((slot + 1) & mask);
        }
    }
    index_storage.sealed = .{
        .records = storage[0..unique_len],
        .table = active_table,
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

pub fn findIndexed(index: *const NodeIndex, digest: *align(1) const hash.Root) ?IndexedNode {
    return dataFromIndex(index).findBorrowed(digest);
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
