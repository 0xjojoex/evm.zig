//! Canonical MPT node RLP encoding shared by the mutation engines.
//!
//! Pure functions over paths, values, and child references; no node
//! representation enters here. Node buffers are caller-provided, and the
//! sizing helpers return exact byte requirements so engines can bound their
//! scratch before writing.

const std = @import("std");
const rlp = @import("rlp");

const errors = @import("error.zig");
const hash = @import("hash.zig");
const nibble = @import("nibble.zig");
const node_codec = @import("node.zig");

const UpdateError = errors.UpdateError;

/// An owned child reference held by a mutable engine node. `unset` marks a
/// node not yet encoded; `empty` a deleted subtree.
pub const Reference = union(enum) {
    unset,
    empty,
    embedded: Embedded,
    hashed: hash.Root,

    pub const Embedded = struct {
        len: u8,
        bytes: [31]u8,
    };

    comptime {
        // This value is stored in every mutable engine node. Padding it to
        // eight-byte alignment costs more than aligned digest loads save.
        std.debug.assert(@sizeOf(Reference) == 33);
        std.debug.assert(@alignOf(Reference) == 1);
    }
};

/// Convert a borrowed decode-side reference into an owned engine reference.
pub fn fromCodec(reference: node_codec.Reference) UpdateError!Reference {
    return switch (reference) {
        .empty => .empty,
        .hashed => |digest| .{ .hashed = digest.* },
        .embedded => |encoded| embedded: {
            if (encoded.len >= 32) return error.InvalidNodeReference;
            var value: Reference.Embedded = .{
                .len = @intCast(encoded.len),
                .bytes = undefined,
            };
            @memcpy(value.bytes[0..encoded.len], encoded);
            break :embedded .{ .embedded = value };
        },
    };
}

pub fn referenceEncodedLen(reference: *const Reference) UpdateError!usize {
    return switch (reference.*) {
        .unset, .empty => error.InvalidNode,
        .hashed => 33,
        .embedded => |*embedded| embedded.len,
    };
}

pub const BufferLengths = struct {
    compact: usize,
    node: usize,
};

pub fn leafBufferLengths(path: []const u8, value: []const u8) UpdateError!BufferLengths {
    return leafPathBufferLengths(path.len, value);
}

pub fn leafPathBufferLengths(path_len: usize, value: []const u8) UpdateError!BufferLengths {
    const compact_len = try compactOutputLen(path_len);
    const payload = try addEncodedLengths(&.{
        try bytesEncodedLenUpperBound(compact_len),
        try bytesEncodedLen(value),
    });
    return .{ .compact = compact_len, .node = try listEncodedLen(payload) };
}

pub fn extensionBufferLengths(path: []const u8, child_reference: *const Reference) UpdateError!BufferLengths {
    return extensionPathBufferLengths(path.len, child_reference);
}

pub fn extensionPathBufferLengths(path_len: usize, child_reference: *const Reference) UpdateError!BufferLengths {
    const compact_len = try compactOutputLen(path_len);
    const payload = try addEncodedLengths(&.{
        try bytesEncodedLenUpperBound(compact_len),
        try referenceEncodedLen(child_reference),
    });
    return .{ .compact = compact_len, .node = try listEncodedLen(payload) };
}

pub fn leaf(
    node_buffer: []u8,
    compact_buffer: []u8,
    path: []const u8,
    value: []const u8,
) UpdateError![]const u8 {
    const compact_path = try compact(compact_buffer, path, true);
    return leafCompact(node_buffer, compact_path, value);
}

pub fn leafPath(
    node_buffer: []u8,
    compact_buffer: []u8,
    path: nibble.Path,
    value: []const u8,
) UpdateError![]const u8 {
    const compact_path = try compactPath(compact_buffer, path, true);
    return leafCompact(node_buffer, compact_path, value);
}

fn leafCompact(node_buffer: []u8, compact_path: []const u8, value: []const u8) UpdateError![]const u8 {
    const payload_len = try addEncodedLengths(&.{
        try bytesEncodedLen(compact_path),
        try bytesEncodedLen(value),
    });
    var writer = try listWriter(node_buffer, payload_len);
    try writeBytes(&writer, compact_path);
    try writeBytes(&writer, value);
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

pub fn extension(
    node_buffer: []u8,
    compact_buffer: []u8,
    path: []const u8,
    child_reference: *const Reference,
) UpdateError![]const u8 {
    if (child_reference.* == .unset or child_reference.* == .empty) return error.InvalidNode;
    const compact_path = try compact(compact_buffer, path, false);
    return extensionCompact(node_buffer, compact_path, child_reference);
}

pub fn extensionPath(
    node_buffer: []u8,
    compact_buffer: []u8,
    path: nibble.Path,
    child_reference: *const Reference,
) UpdateError![]const u8 {
    if (child_reference.* == .unset or child_reference.* == .empty) return error.InvalidNode;
    const compact_path = try compactPath(compact_buffer, path, false);
    return extensionCompact(node_buffer, compact_path, child_reference);
}

fn extensionCompact(
    node_buffer: []u8,
    compact_path: []const u8,
    child_reference: *const Reference,
) UpdateError![]const u8 {
    const payload_len = try addEncodedLengths(&.{
        try bytesEncodedLen(compact_path),
        try referenceEncodedLen(child_reference),
    });
    var writer = try listWriter(node_buffer, payload_len);
    try writeBytes(&writer, compact_path);
    try writeReference(&writer, child_reference);
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

/// Hex-prefix-encode a nibble path, flagged `terminal` for a leaf.
pub fn compact(out: []u8, path: []const u8, terminal: bool) UpdateError![]const u8 {
    const out_len = try compactOutputLen(path.len);
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

pub fn compactPath(out: []u8, path: nibble.Path, terminal: bool) UpdateError![]const u8 {
    return nibble.encodeCompact(out, path, terminal) catch error.ResourceLimitExceeded;
}

pub fn compactOutputLen(path_len: usize) UpdateError!usize {
    return std.math.add(usize, 1, path_len / 2) catch
        error.ResourceLimitExceeded;
}

pub fn bytesEncodedLenUpperBound(value_len: usize) UpdateError!usize {
    const prefix_len: usize = if (value_len < 56)
        1
    else
        std.math.add(usize, 1, lengthByteLen(value_len)) catch
            return error.ResourceLimitExceeded;
    return std.math.add(usize, prefix_len, value_len) catch
        error.ResourceLimitExceeded;
}

pub fn bytesEncodedLen(value: []const u8) UpdateError!usize {
    if (value.len == 1 and value[0] < 0x80) return 1;
    const prefix_len: usize = if (value.len < 56)
        1
    else
        std.math.add(usize, 1, lengthByteLen(value.len)) catch
            return error.ResourceLimitExceeded;
    return std.math.add(usize, prefix_len, value.len) catch
        error.ResourceLimitExceeded;
}

pub fn listEncodedLen(payload_len: usize) UpdateError!usize {
    return std.math.add(usize, listPrefixLen(payload_len), payload_len) catch
        error.ResourceLimitExceeded;
}

pub fn listPrefixLen(payload_len: usize) usize {
    return if (payload_len < 56) 1 else 1 + lengthByteLen(payload_len);
}

fn lengthByteLen(value: usize) usize {
    return (@bitSizeOf(usize) - @clz(value) + 7) / 8;
}

pub fn addEncodedLengths(lengths: []const usize) UpdateError!usize {
    var total: usize = 0;
    for (lengths) |len| {
        total = std.math.add(usize, total, len) catch
            return error.ResourceLimitExceeded;
    }
    return total;
}

/// A fixed writer over `node_buffer` with the list prefix already written.
pub fn listWriter(node_buffer: []u8, payload_len: usize) UpdateError!rlp.Writer {
    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    const prefix = rlp.listPrefix(&prefix_buffer, payload_len);
    const total_len = std.math.add(usize, prefix.len, payload_len) catch
        return error.ResourceLimitExceeded;
    if (total_len > node_buffer.len) return error.ResourceLimitExceeded;
    @memcpy(node_buffer[0..prefix.len], prefix);
    return rlp.Writer.fixed(node_buffer[prefix.len..total_len]);
}

pub fn writeBytes(writer: *rlp.Writer, value: []const u8) UpdateError!void {
    writer.bytes(value) catch |err| switch (err) {
        error.NoSpaceLeft => return error.ResourceLimitExceeded,
        error.OutOfMemory => unreachable,
    };
}

pub fn writeReference(writer: *rlp.Writer, reference: *const Reference) UpdateError!void {
    switch (reference.*) {
        .unset, .empty => return error.InvalidNode,
        .hashed => |*digest| try writeBytes(writer, digest),
        .embedded => |*embedded| {
            const item = try rlp.parseExact(embedded.bytes[0..embedded.len]);
            writer.raw(item) catch |err| switch (err) {
                error.NoSpaceLeft => return error.ResourceLimitExceeded,
                error.OutOfMemory => unreachable,
            };
        },
    }
}

pub fn writeCodecReference(writer: *rlp.Writer, reference: node_codec.Reference) UpdateError!void {
    switch (reference) {
        .empty => return error.InvalidNode,
        .hashed => |digest| try writeBytes(writer, digest),
        .embedded => |encoded| {
            const item = try rlp.parseExact(encoded);
            writer.raw(item) catch |err| switch (err) {
                error.NoSpaceLeft => return error.ResourceLimitExceeded,
                error.OutOfMemory => unreachable,
            };
        },
    }
}
