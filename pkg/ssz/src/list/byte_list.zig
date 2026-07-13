const std = @import("std");
const ssz = @import("../lib.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;
const fixed = @import("../basic/fixed.zig");
const schema_limit = @import("../schema_limit.zig");

/// Return the codec for SSZ `ByteList[limit]`.
/// `limit` is an arbitrary-precision schema capacity; runtime lengths remain `usize`.
pub fn ByteList(comptime limit: comptime_int) type {
    return ByteListCodec(limit, false);
}

/// Codec for SSZ `ProgressiveByteList`.
pub const ProgressiveByteList = ByteListCodec(0, true);

fn ByteListCodec(comptime limit: comptime_int, comptime progressive: bool) type {
    comptime schema_limit.assertValid(limit);
    return struct {
        pub const Value = []const u8;
        pub const kind: codec.Kind = if (progressive) .progressive_list else .list;
        pub const element_codec = fixed.Fixed(u8);
        pub const max_length: ?comptime_int = if (progressive) null else limit;
        pub const is_progressive = progressive;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = true;

        pub fn encodedLen(value: Value) Error!usize {
            try validate(value);
            return value.len;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;
            @memcpy(out[0..len], value);
            return out[0..len];
        }

        /// Decode by borrowing the validated input bytes.
        pub fn decode(bytes: []const u8) Error!Value {
            try validate(bytes);
            return bytes;
        }

        pub fn validate(value: []const u8) Error!void {
            if (!progressive and schema_limit.exceededBy(value.len, limit)) return error.ListLimitExceeded;
            if (value.len > std.math.maxInt(u32)) return error.EncodedLengthOverflow;
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Value {
            try validate(bytes);
            return allocator.dupe(u8, bytes);
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            allocator.free(value.*);
            value.* = &.{};
        }
    };
}

test "SSZ ByteList encodes into caller storage and decodes by borrowing" {
    const ExtraData = ssz.ByteList(8);
    var storage: [8]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 3), try ExtraData.encodedLen("abc"));
    const encoded = try ExtraData.encode(&storage, "abc");
    try std.testing.expectEqualSlices(u8, "abc", encoded);

    const decoded = try ExtraData.decode(encoded);
    try std.testing.expectEqualSlices(u8, "abc", decoded);
    try std.testing.expectEqual(encoded.ptr, decoded.ptr);
}

test "SSZ ByteList accepts empty and exact-limit values" {
    const Bytes = ssz.ByteList(4);
    var storage: [4]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), (try Bytes.encode(&storage, "")).len);
    try std.testing.expectEqualSlices(u8, "1234", try Bytes.encode(&storage, "1234"));
    try std.testing.expectEqual(@as(usize, 0), (try Bytes.decode("")).len);
}

test "SSZ ByteList keeps schema capacity independent from runtime length" {
    const Bytes = ssz.ByteList(1 << 120);
    var storage: [3]u8 = undefined;

    try std.testing.expect(comptime Bytes.max_length.? == 1 << 120);
    try std.testing.expectEqualSlices(u8, "abc", try Bytes.encode(&storage, "abc"));
    try std.testing.expectEqualSlices(u8, "abc", try Bytes.decode("abc"));
}

test "SSZ ByteList enforces its declared limit and output capacity" {
    const Bytes = ssz.ByteList(4);
    var short_storage: [2]u8 = undefined;
    var enough_storage: [4]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, Bytes.encode(&short_storage, "abc"));
    try std.testing.expectError(error.ListLimitExceeded, Bytes.encode(&enough_storage, "12345"));
    try std.testing.expectError(error.ListLimitExceeded, Bytes.decode("12345"));
}

test "SSZ ProgressiveByteList borrows validated bytes without a schema limit" {
    var storage: [5]u8 = undefined;
    const encoded = try ssz.ProgressiveByteList.encode(&storage, "abcde");

    try std.testing.expect(ssz.ProgressiveByteList.is_progressive);
    try std.testing.expectEqualStrings("abcde", try ssz.ProgressiveByteList.decode(encoded));
}
