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
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        hash: hash.Root,
        decoded: node.Node,
    };

    pub fn init(allocator: std.mem.Allocator) LookupCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LookupCache) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn decode(
        self: *LookupCache,
        digest: hash.Root,
        encoded: []const u8,
        require_branch: bool,
    ) (std.mem.Allocator.Error || LookupError)!node.Node {
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, &entry.hash, &digest)) continue;
            if (require_branch and entry.decoded != .branch) {
                return error.NonCanonicalNode;
            }
            return entry.decoded;
        }
        const decoded = try node.decode(encoded, require_branch);
        try self.entries.append(self.allocator, .{
            .hash = digest,
            .decoded = decoded,
        });
        return decoded;
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

    /// The encoded node whose hash equals `digest`, or null. Records must be
    /// sorted ascending by hash (as produced by `indexNodes`).
    pub fn find(self: IndexData, digest: hash.Root) ?[]const u8 {
        var low: usize = 0;
        var high = self.records.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, &self.records[mid].hash, &digest)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return self.records[mid].encoded,
            }
        }
        return null;
    }
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
    return dataFromIndex(index).find(digest);
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

    var resolved = ResolvedReference{
        .encoded = find(index, root) orelse return error.MissingNode,
        .hash = root,
    };
    var depth: usize = 0;
    var steps: usize = 0;
    var extension_parent = false;

    while (true) {
        steps = std.math.add(usize, steps, 1) catch return error.ResourceLimitExceeded;
        if (steps > step_capacity) return error.ResourceLimitExceeded;

        const decoded = if (cache) |active|
            if (resolved.hash) |digest|
                try active.decode(digest, resolved.encoded, extension_parent)
            else
                try node.decode(resolved.encoded, extension_parent)
        else
            try node.decode(resolved.encoded, extension_parent);
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

const ResolvedReference = struct {
    encoded: []const u8,
    hash: ?hash.Root,
};

fn resolveRequiredReference(index: *const NodeIndex, reference: node.Reference) LookupError!ResolvedReference {
    return (try resolveReference(index, reference)) orelse return error.InvalidNodeReference;
}

fn resolveReference(index: *const NodeIndex, reference: node.Reference) LookupError!?ResolvedReference {
    return switch (reference) {
        .empty => null,
        .embedded => |embedded| .{ .encoded = embedded, .hash = null },
        .hashed => |digest| {
            const encoded = find(index, digest) orelse return error.MissingNode;
            if (encoded.len < 32) return error.InvalidNodeReference;
            return .{ .encoded = encoded, .hash = digest };
        },
    };
}

fn recordLessThan(_: void, lhs: NodeRecord, rhs: NodeRecord) bool {
    return std.mem.order(u8, &lhs.hash, &rhs.hash) == .lt;
}
