const std = @import("std");
const ssz = @import("lib.zig");
const codec = @import("codec.zig");

/// Select a codec's input-backed decode path without changing its value shape.
///
/// Decoded values may point into `bytes`; callers must keep those bytes alive
/// and unchanged for the complete value lifetime. The codec remains composable
/// inside lists and containers, which may still allocate their own structure.
pub fn Borrowed(comptime Codec: type) type {
    comptime {
        codec.assertCodec(Codec);
        if (!Codec.requires_allocator) {
            @compileError("ssz.Borrowed requires an allocating codec");
        }
        if (!std.meta.hasFn(Codec, "decode")) {
            @compileError("ssz.Borrowed codec is missing an input-backed decode");
        }
    }

    return struct {
        pub const Value = Codec.Value;
        pub const kind = Codec.kind;
        pub const wire_codec = Codec;
        pub const is_variable_size = Codec.is_variable_size;
        pub const fixed_size = Codec.fixed_size;
        pub const requires_allocator = false;
        pub const encodedLen = Codec.encodedLen;
        pub const encode = Codec.encode;
        pub const decode = Codec.decode;
        pub const validate = Codec.validate;

        pub fn toWire(value: Value) Codec.Value {
            return value;
        }
    };
}

test "SSZ Borrowed selects ByteList input-backed decoding" {
    const Owned = ssz.ByteList(4);
    const InputBacked = ssz.Borrowed(Owned);
    const encoded = [_]u8{ 'a', 'b', 'c' };
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);

    const decoded = try ssz.decodeOwned(InputBacked, fixed.allocator(), &encoded);
    try std.testing.expect(!InputBacked.requires_allocator);
    try std.testing.expect(InputBacked.Value == Owned.Value);
    try std.testing.expectEqualSlices(u8, "abc", decoded);
    try std.testing.expectEqual(encoded[0..].ptr, decoded.ptr);
    try std.testing.expectError(
        error.ListLimitExceeded,
        ssz.decodeOwned(InputBacked, fixed.allocator(), "12345"),
    );
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(Owned, decoded),
        try ssz.hashTreeRoot(InputBacked, decoded),
    );
}

test "SSZ Borrowed composes with ListOf using an owned index" {
    const Items = ssz.ListOf(ssz.Borrowed(ssz.ByteList(4)), 2);
    const encoded = [_]u8{ 8, 0, 0, 0, 9, 0, 0, 0, 'a', 'b', 'c' };

    var decoded = try ssz.decodeOwned(Items, std.testing.allocator, &encoded);
    defer ssz.deinitOwned(Items, std.testing.allocator, &decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualSlices(u8, "a", decoded[0]);
    try std.testing.expectEqualSlices(u8, "bc", decoded[1]);
    try std.testing.expectEqual(encoded[8..].ptr, decoded[0].ptr);
    try std.testing.expectEqual(encoded[9..].ptr, decoded[1].ptr);
}

test "SSZ Borrowed composes inside Container" {
    const Value = struct {
        count: u16,
        items: []const []const u8,
    };
    const Items = ssz.ListOf(ssz.Borrowed(ssz.ByteList(4)), 2);
    const BorrowedContainer = ssz.Container(Value, .{ .items = Items });
    const OwnedContainer = ssz.Container(Value, .{
        .items = ssz.ListOf(ssz.ByteList(4), 2),
    });
    const value = Value{ .count = 2, .items = &.{ "a", "bc" } };
    var storage: [17]u8 = undefined;
    const encoded = try BorrowedContainer.encode(&storage, value);

    var decoded = try ssz.decodeOwned(BorrowedContainer, std.testing.allocator, encoded);
    defer ssz.deinitOwned(BorrowedContainer, std.testing.allocator, &decoded);

    try std.testing.expectEqual(value.count, decoded.count);
    try std.testing.expectEqualSlices(u8, value.items[0], decoded.items[0]);
    try std.testing.expectEqualSlices(u8, value.items[1], decoded.items[1]);
    const input_start = @intFromPtr(encoded.ptr);
    const input_end = input_start + encoded.len;
    for (decoded.items) |item| {
        const item_start = @intFromPtr(item.ptr);
        try std.testing.expect(item_start >= input_start and item_start <= input_end);
    }
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(OwnedContainer, value),
        try ssz.hashTreeRoot(BorrowedContainer, decoded),
    );
}
