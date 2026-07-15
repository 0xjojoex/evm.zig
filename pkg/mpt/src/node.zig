//! Decoding of RLP-encoded trie nodes into leaf/extension/branch structures.

const rlp = @import("rlp");

const Error = @import("error.zig").CodecError;
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");

/// Reference to a child node: absent, inline (encoded < 32 bytes), or by hash.
pub const Reference = union(enum) {
    empty,
    embedded: []const u8,
    hashed: hash.Root,
};

/// A decoded trie node. Paths and values borrow from the encoded input.
pub const Node = union(enum) {
    leaf: Leaf,
    extension: Extension,
    branch: Branch,

    /// Terminal node holding the remaining key path and its value.
    pub const Leaf = struct {
        path: nibble.CompactPath,
        value: []const u8,
    };

    /// Shared-prefix node pointing at a single child.
    pub const Extension = struct {
        path: nibble.CompactPath,
        child: Reference,
    };

    /// Sixteen-way fan-out node with an optional value for a key ending here.
    pub const Branch = struct {
        children: [16]Reference,
        value: ?[]const u8,
    };
};

/// Decode one RLP-encoded node. When `require_branch` is set the node must be a
/// branch, rejecting non-canonical structure reached through an extension. The
/// result borrows from `encoded`.
pub fn decode(encoded: []const u8, require_branch: bool) Error!Node {
    const item = try rlp.parseExact(encoded);
    var fields = item.listCursor() catch return error.InvalidNode;
    var items: [17]rlp.Item = undefined;
    var field_count: usize = 0;
    while (!fields.isDone()) {
        if (field_count == items.len) return error.InvalidNode;
        items[field_count] = try fields.next();
        field_count += 1;
    }
    if (require_branch and field_count != 17) return error.NonCanonicalNode;
    return switch (field_count) {
        2 => decodeShort(items[0], items[1]),
        17 => decodeBranch(&items),
        else => error.InvalidNode,
    };
}

fn decodeShort(compact_item: rlp.Item, value_or_reference: rlp.Item) Error!Node {
    const compact = compact_item.asBytes() catch return error.InvalidNode;
    const path = try nibble.CompactPath.decode(compact);

    if (path.terminal) {
        const value = value_or_reference.asBytes() catch return error.InvalidNode;
        if (value.len == 0) return error.NonCanonicalNode;
        return .{ .leaf = .{ .path = path, .value = value } };
    }

    if (path.len == 0) return error.NonCanonicalNode;
    const child = try decodeReference(value_or_reference);
    if (child == .empty) return error.InvalidNodeReference;
    return .{ .extension = .{ .path = path, .child = child } };
}

fn decodeBranch(items: *const [17]rlp.Item) Error!Node {
    var branch: Node.Branch = .{
        .children = [_]Reference{.empty} ** 16,
        .value = null,
    };
    var occupied: usize = 0;
    for (items[0..16], 0..) |item, index| {
        branch.children[index] = try decodeReference(item);
        if (branch.children[index] != .empty) occupied += 1;
    }

    const value = items[16].asBytes() catch return error.InvalidNode;
    if (value.len > 0) {
        branch.value = value;
        occupied += 1;
    }
    if (occupied < 2) return error.NonCanonicalNode;
    return .{ .branch = branch };
}

fn decodeReference(item: rlp.Item) Error!Reference {
    return switch (item) {
        .list => {
            if (item.encoded().len >= 32) return error.InvalidNodeReference;
            return .{ .embedded = item.encoded() };
        },
        .bytes => |span| switch (span.payload.len) {
            0 => .empty,
            32 => hashed: {
                var digest: hash.Root = undefined;
                @memcpy(&digest, span.payload);
                break :hashed .{ .hashed = digest };
            },
            else => error.InvalidNodeReference,
        },
    };
}
