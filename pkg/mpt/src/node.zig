//! Decoding of RLP-encoded trie nodes into leaf/extension/branch structures.

const std = @import("std");
const rlp = @import("rlp");

const Error = @import("error.zig").CodecError;
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");

/// Hashed references borrow their exact-width payload from the encoded node.
pub const HashedReference = *align(1) const hash.Root;

/// Reference to a child node: absent, inline (encoded < 32 bytes), or by hash.
pub const Reference = union(enum) {
    empty,
    embedded: []const u8,
    hashed: HashedReference,
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

/// Compact validated reference used while building the catalog. Offsets borrow
/// from the enclosing encoded node without retaining wide slice unions.
pub const CatalogReference = struct {
    // The record already occupies eight bytes. Give that stride its natural
    // RV64 alignment so catalog decode/link can move it as one word.
    offset: u32 align(8),
    len: u8,
    kind: Kind,

    pub const Kind = enum(u8) {
        empty,
        embedded,
        hashed,
    };

    pub fn reference(self: CatalogReference, encoded: []const u8) Reference {
        return switch (self.kind) {
            .empty => .empty,
            .embedded => .{ .embedded = encoded[self.offset..][0..self.len] },
            .hashed => .{ .hashed = @ptrCast(encoded[self.offset..][0..32].ptr) },
        };
    }

    comptime {
        std.debug.assert(@sizeOf(CatalogReference) == 8);
        std.debug.assert(@alignOf(CatalogReference) == 8);
    }
};

pub const CatalogBranch = struct {
    children: [16]CatalogReference,
    value: ?[]const u8,

    comptime {
        std.debug.assert(@sizeOf(CatalogBranch) == 144);
        std.debug.assert(@alignOf(CatalogBranch) == 8);
    }
};

/// Catalog-oriented decode result. Branch children retain only compact spans
/// after validation instead of the wider general-purpose reference union.
pub const CatalogNode = union(enum) {
    leaf: Node.Leaf,
    extension: Node.Extension,
    branch: CatalogBranch,
};

/// Decode one RLP-encoded node. When `require_branch` is set the node must be a
/// branch, rejecting non-canonical structure reached through an extension. The
/// result borrows from `encoded`.
pub fn decode(encoded: []const u8, require_branch: bool) Error!Node {
    return decodeWithBranchMode(encoded, require_branch, .full);
}

/// Decode short nodes normally while compacting branch references in one pass
/// for catalog construction.
pub fn decodeForCatalog(encoded: []const u8) Error!CatalogNode {
    const item = try rlp.parseExact(encoded);
    var fields = item.listCursor() catch return error.InvalidNode;
    if (fields.isDone()) return error.InvalidNode;
    const first = try fields.next();
    if (fields.isDone()) return error.InvalidNode;
    const second = try fields.next();
    if (fields.isDone()) {
        return switch (try decodeShort(first, second)) {
            .leaf => |leaf| .{ .leaf = leaf },
            .extension => |extension| .{ .extension = extension },
            .branch => unreachable,
        };
    }
    var branch: CatalogBranch = undefined;
    branch.children[0] = try decodeCatalogReference(encoded, first);
    branch.children[1] = try decodeCatalogReference(encoded, second);
    var occupied: usize = 0;
    if (branch.children[0].kind != .empty) occupied += 1;
    if (branch.children[1].kind != .empty) occupied += 1;
    for (2..16) |index| {
        if (fields.isDone()) return error.InvalidNode;
        branch.children[index] = try decodeCatalogReference(encoded, try fields.next());
        if (branch.children[index].kind != .empty) occupied += 1;
    }
    if (fields.isDone()) return error.InvalidNode;
    const value = (try fields.next()).asBytes() catch return error.InvalidNode;
    if (!fields.isDone()) return error.InvalidNode;
    branch.value = if (value.len == 0) null else value;
    if (branch.value != null) occupied += 1;
    if (occupied < 2) return error.NonCanonicalNode;
    return .{ .branch = branch };
}

fn decodeCatalogReference(encoded: []const u8, item: rlp.Item) Error!CatalogReference {
    const reference = try decodeReference(item);
    return switch (reference) {
        .empty => .{ .offset = 0, .len = 0, .kind = .empty },
        .embedded => |child| .{
            .offset = try catalogOffset(encoded, child),
            .len = @intCast(child.len),
            .kind = .embedded,
        },
        .hashed => |digest| .{
            .offset = try catalogOffset(encoded, digest),
            .len = 32,
            .kind = .hashed,
        },
    };
}

fn catalogOffset(encoded: []const u8, span: []const u8) Error!u32 {
    const base = @intFromPtr(encoded.ptr);
    const start = @intFromPtr(span.ptr);
    if (start < base) return error.InvalidNode;
    const offset = start - base;
    if (offset > encoded.len or span.len > encoded.len - offset) return error.InvalidNode;
    return std.math.cast(u32, offset) orelse error.InvalidNode;
}

/// Decode one node for a single proof path. Branch validation still examines
/// every reference, but only the selected child is materialized.
pub fn decodeForLookup(
    encoded: []const u8,
    require_branch: bool,
    selected_child: ?u4,
) Error!Node {
    return decodeWithBranchMode(
        encoded,
        require_branch,
        if (selected_child) |index| .{ .selected = index } else .none,
    );
}

const BranchMode = union(enum) {
    full,
    none,
    selected: u4,
};

fn decodeWithBranchMode(
    encoded: []const u8,
    require_branch: bool,
    branch_mode: BranchMode,
) Error!Node {
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
        17 => decodeBranch(&items, branch_mode),
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

fn decodeBranch(items: *const [17]rlp.Item, mode: BranchMode) Error!Node {
    var branch: Node.Branch = .{
        .children = [_]Reference{.empty} ** 16,
        .value = null,
    };
    var occupied: usize = 0;
    for (items[0..16], 0..) |item, index| {
        const materialize = switch (mode) {
            .full => true,
            .none => false,
            .selected => |selected| index == selected,
        };
        if (materialize) {
            branch.children[index] = try decodeReference(item);
            if (branch.children[index] != .empty) occupied += 1;
        } else if (try hasReference(item)) {
            occupied += 1;
        }
    }

    const value = items[16].asBytes() catch return error.InvalidNode;
    if (value.len > 0) {
        branch.value = value;
        occupied += 1;
    }
    if (occupied < 2) return error.NonCanonicalNode;
    return .{ .branch = branch };
}

fn hasReference(item: rlp.Item) Error!bool {
    return switch (item) {
        .list => {
            if (item.encoded().len >= 32) return error.InvalidNodeReference;
            return true;
        },
        .bytes => |span| switch (span.payload.len) {
            0 => false,
            32 => true,
            else => error.InvalidNodeReference,
        },
    };
}

fn decodeReference(item: rlp.Item) Error!Reference {
    return switch (item) {
        .list => {
            if (item.encoded().len >= 32) return error.InvalidNodeReference;
            return .{ .embedded = item.encoded() };
        },
        .bytes => |span| switch (span.payload.len) {
            0 => .empty,
            32 => .{ .hashed = @ptrCast(span.payload.ptr) },
            else => error.InvalidNodeReference,
        },
    };
}
