//! Minimal SSZ helpers for versioned stateless wire codecs.
//! This is intentionally scoped, not a general SSZ implementation.

const std = @import("std");
const crypto = @import("../crypto.zig");

pub const bytes_per_length_offset = 4;

pub const Error = error{
    InvalidBool,
    InvalidByteLength,
    InvalidFirstOffset,
    OffsetOutOfBounds,
    OffsetsAreNotMonotonic,
    InvalidListLength,
};

pub const Field = union(enum) {
    fixed: []const u8,
    variable: []const u8,
};

pub fn readU64(bytes: []const u8) Error!u64 {
    if (bytes.len != 8) return error.InvalidByteLength;
    return std.mem.readInt(u64, bytes[0..8], .little);
}

pub fn readBool(bytes: []const u8) Error!bool {
    if (bytes.len != 1) return error.InvalidByteLength;
    return switch (bytes[0]) {
        0 => false,
        1 => true,
        else => error.InvalidBool,
    };
}

pub fn writeU64(out: *[8]u8, value: u64) void {
    std.mem.writeInt(u64, out, value, .little);
}

pub fn writeBool(out: *[1]u8, value: bool) void {
    out[0] = @intFromBool(value);
}

pub fn encodeContainer(allocator: std.mem.Allocator, comptime field_count: usize, fields: [field_count]Field) std.mem.Allocator.Error![]u8 {
    var fixed_len: usize = 0;
    var variable_len: usize = 0;
    for (fields) |field| switch (field) {
        .fixed => |bytes| fixed_len += bytes.len,
        .variable => |bytes| {
            fixed_len += bytes_per_length_offset;
            variable_len += bytes.len;
        },
    };

    const out = try allocator.alloc(u8, fixed_len + variable_len);
    errdefer allocator.free(out);

    var fixed_offset: usize = 0;
    var variable_offset = fixed_len;
    for (fields) |field| switch (field) {
        .fixed => |bytes| {
            @memcpy(out[fixed_offset..][0..bytes.len], bytes);
            fixed_offset += bytes.len;
        },
        .variable => |bytes| {
            putOffset(out[fixed_offset..][0..bytes_per_length_offset], variable_offset);
            fixed_offset += bytes_per_length_offset;
            @memcpy(out[variable_offset..][0..bytes.len], bytes);
            variable_offset += bytes.len;
        },
    };
    return out;
}

pub fn splitVariableFields(comptime field_count: usize, bytes: []const u8) Error![field_count][]const u8 {
    const fixed_part_len = field_count * bytes_per_length_offset;
    if (bytes.len < fixed_part_len) return error.InvalidByteLength;

    var offsets: [field_count]usize = undefined;
    for (&offsets, 0..) |*offset, i| {
        offset.* = readOffset(bytes[i * bytes_per_length_offset ..][0..bytes_per_length_offset]);
        if (i == 0) {
            if (offset.* != fixed_part_len) return error.InvalidFirstOffset;
        } else if (offset.* < offsets[i - 1]) {
            return error.OffsetsAreNotMonotonic;
        }
        if (offset.* > bytes.len) return error.OffsetOutOfBounds;
    }

    var fields: [field_count][]const u8 = undefined;
    for (&fields, 0..) |*field, i| {
        const end = if (i + 1 < field_count) offsets[i + 1] else bytes.len;
        field.* = bytes[offsets[i]..end];
    }
    return fields;
}

pub fn decodeByteListList(allocator: std.mem.Allocator, bytes: []const u8) (std.mem.Allocator.Error || Error)![]const []const u8 {
    if (bytes.len == 0) return allocator.alloc([]const u8, 0);
    if (bytes.len < bytes_per_length_offset) return error.InvalidByteLength;
    const first_offset = readOffset(bytes[0..bytes_per_length_offset]);
    if (first_offset == 0 or first_offset % bytes_per_length_offset != 0) return error.InvalidFirstOffset;
    if (first_offset > bytes.len) return error.OffsetOutOfBounds;

    const count = first_offset / bytes_per_length_offset;
    const out = try allocator.alloc([]const u8, count);
    errdefer allocator.free(out);

    var previous = first_offset;
    for (out, 0..) |*item, i| {
        const start = readOffset(bytes[i * bytes_per_length_offset ..][0..bytes_per_length_offset]);
        if (start < previous) return error.OffsetsAreNotMonotonic;
        if (start > bytes.len) return error.OffsetOutOfBounds;
        const end = if (i + 1 < count)
            readOffset(bytes[(i + 1) * bytes_per_length_offset ..][0..bytes_per_length_offset])
        else
            bytes.len;
        if (end < start) return error.OffsetsAreNotMonotonic;
        if (end > bytes.len) return error.OffsetOutOfBounds;
        item.* = bytes[start..end];
        previous = start;
    }
    return out;
}

pub fn encodeByteListList(allocator: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error![]u8 {
    if (items.len == 0) return allocator.alloc(u8, 0);

    var payload_len: usize = items.len * bytes_per_length_offset;
    for (items) |item| payload_len += item.len;
    const out = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(out);

    var variable_offset = items.len * bytes_per_length_offset;
    for (items, 0..) |item, i| {
        putOffset(out[i * bytes_per_length_offset ..][0..bytes_per_length_offset], variable_offset);
        @memcpy(out[variable_offset..][0..item.len], item);
        variable_offset += item.len;
    }
    return out;
}

pub fn encodeFixedList(allocator: std.mem.Allocator, comptime item_len: usize, items: []const [item_len]u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, item_len * items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| {
        @memcpy(out[i * item_len ..][0..item_len], &item);
    }
    return out;
}

pub fn validateFixedList(bytes: []const u8, comptime item_len: usize) Error!void {
    if (bytes.len % item_len != 0) return error.InvalidListLength;
}

pub fn fixedBytesRoot(bytes: []const u8) [32]u8 {
    var out = [_]u8{0} ** 32;
    @memcpy(out[0..bytes.len], bytes);
    return out;
}

pub fn uint64Root(value: u64) [32]u8 {
    var out = [_]u8{0} ** 32;
    std.mem.writeInt(u64, out[0..8], value, .little);
    return out;
}

pub fn boolRoot(value: bool) [32]u8 {
    var out = [_]u8{0} ** 32;
    out[0] = @intFromBool(value);
    return out;
}

pub fn bytesVectorRoot(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![32]u8 {
    const chunks = try packBytes(allocator, bytes);
    defer allocator.free(chunks);
    return try merkleize(allocator, chunks);
}

pub fn bytesListRoot(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![32]u8 {
    const root = try bytesVectorRoot(allocator, bytes);
    return mixInLength(root, bytes.len);
}

pub fn bytesListRootLimit(allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) (std.mem.Allocator.Error || Error)![32]u8 {
    if (bytes.len > max_bytes) return error.InvalidListLength;
    const chunks = try packBytes(allocator, bytes);
    defer allocator.free(chunks);
    const max_chunks = (max_bytes + 31) / 32;
    const root = try merkleizeLimit(allocator, chunks, max_chunks);
    return mixInLength(root, bytes.len);
}

pub fn listRoot(allocator: std.mem.Allocator, roots: []const [32]u8) std.mem.Allocator.Error![32]u8 {
    const root = try merkleize(allocator, roots);
    return mixInLength(root, roots.len);
}

pub fn listRootLimit(allocator: std.mem.Allocator, roots: []const [32]u8, max_items: usize) (std.mem.Allocator.Error || Error)![32]u8 {
    if (roots.len > max_items) return error.InvalidListLength;
    const root = try merkleizeLimit(allocator, roots, max_items);
    return mixInLength(root, roots.len);
}

pub fn containerRoot(allocator: std.mem.Allocator, roots: []const [32]u8) std.mem.Allocator.Error![32]u8 {
    return merkleize(allocator, roots);
}

pub fn mixInLength(root: [32]u8, len: usize) [32]u8 {
    var data = [_]u8{0} ** 64;
    @memcpy(data[0..32], &root);
    std.mem.writeInt(u64, data[32..40], @intCast(len), .little);
    return crypto.sha256(&data);
}

pub fn merkleize(allocator: std.mem.Allocator, chunks: []const [32]u8) std.mem.Allocator.Error![32]u8 {
    if (chunks.len == 0) return [_]u8{0} ** 32;
    if (chunks.len == 1) return chunks[0];

    const padded_len = try ceilPowerOfTwo(allocator, chunks.len);
    var level = try allocator.alloc([32]u8, padded_len);
    defer allocator.free(level);
    @memcpy(level[0..chunks.len], chunks);
    @memset(level[chunks.len..], [_]u8{0} ** 32);

    var width = padded_len;
    while (width > 1) : (width /= 2) {
        for (0..width / 2) |i| {
            level[i] = hashPair(level[i * 2], level[i * 2 + 1]);
        }
    }
    return level[0];
}

pub fn merkleizeLimit(_: std.mem.Allocator, chunks: []const [32]u8, limit: usize) (std.mem.Allocator.Error || Error)![32]u8 {
    if (limit == 0) {
        if (chunks.len == 0) return [_]u8{0} ** 32;
        return error.InvalidListLength;
    }
    if (chunks.len > limit) return error.InvalidListLength;
    const leaf_count = ceilPowerOfTwoValue(limit);
    return merkleizeRange(chunks, 0, leaf_count, log2ExactPowerOfTwo(leaf_count));
}

fn merkleizeRange(chunks: []const [32]u8, start: usize, width: usize, depth: usize) [32]u8 {
    if (start >= chunks.len) return zeroHash(depth);
    if (width == 1) return chunks[start];
    const half = width / 2;
    return hashPair(
        merkleizeRange(chunks, start, half, depth - 1),
        merkleizeRange(chunks, start + half, half, depth - 1),
    );
}

fn zeroHash(depth: usize) [32]u8 {
    var out = [_]u8{0} ** 32;
    for (0..depth) |_| out = hashPair(out, out);
    return out;
}

fn packBytes(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const [32]u8 {
    if (bytes.len == 0) return allocator.alloc([32]u8, 0);
    const count = (bytes.len + 31) / 32;
    const chunks = try allocator.alloc([32]u8, count);
    errdefer allocator.free(chunks);
    for (chunks, 0..) |*chunk, i| {
        @memset(chunk, 0);
        const start = i * 32;
        const copied = @min(32, bytes.len - start);
        @memcpy(chunk[0..copied], bytes[start..][0..copied]);
    }
    return chunks;
}

fn hashPair(left: [32]u8, right: [32]u8) [32]u8 {
    var data: [64]u8 = undefined;
    @memcpy(data[0..32], &left);
    @memcpy(data[32..64], &right);
    return crypto.sha256(&data);
}

fn ceilPowerOfTwo(_: std.mem.Allocator, value: usize) std.mem.Allocator.Error!usize {
    return ceilPowerOfTwoValue(value);
}

fn ceilPowerOfTwoValue(value: usize) usize {
    var out: usize = 1;
    while (out < value) out *= 2;
    return out;
}

fn log2ExactPowerOfTwo(value: usize) usize {
    var remaining = value;
    var out: usize = 0;
    while (remaining > 1) : (remaining /= 2) out += 1;
    return out;
}

fn putOffset(out: []u8, offset: usize) void {
    std.mem.writeInt(u32, out[0..bytes_per_length_offset], @intCast(offset), .little);
}

fn readOffset(bytes: []const u8) usize {
    return std.mem.readInt(u32, bytes[0..bytes_per_length_offset], .little);
}

test "container offsets round-trip variable fields" {
    const encoded = try encodeContainer(std.testing.allocator, 3, .{
        .{ .variable = "abc" },
        .{ .variable = "" },
        .{ .variable = "de" },
    });
    defer std.testing.allocator.free(encoded);

    const fields = try splitVariableFields(3, encoded);
    try std.testing.expectEqualSlices(u8, "abc", fields[0]);
    try std.testing.expectEqualSlices(u8, "", fields[1]);
    try std.testing.expectEqualSlices(u8, "de", fields[2]);
}

test "byte-list list encodes empty and non-empty items" {
    const items = [_][]const u8{ "aa", "", "bbb" };
    const encoded = try encodeByteListList(std.testing.allocator, &items);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeByteListList(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    try std.testing.expectEqualSlices(u8, "aa", decoded[0]);
    try std.testing.expectEqualSlices(u8, "", decoded[1]);
    try std.testing.expectEqualSlices(u8, "bbb", decoded[2]);
}

test "byte-list list rejects short non-empty offset table" {
    try std.testing.expectError(error.InvalidByteLength, decodeByteListList(std.testing.allocator, "\x01"));
}
