const std = @import("std");
const ssz = @import("../lib.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;
const sequence = @import("../variable_sequence.zig");
const schema_limit = @import("../schema_limit.zig");

/// Return the codec for SSZ `List[ElementCodec, limit]`.
/// `limit` is an arbitrary-precision schema capacity; runtime lengths remain `usize`.
pub fn ListOf(comptime ElementCodec: type, comptime limit: comptime_int) type {
    return ListCodec(ElementCodec, limit, false);
}

/// Return the codec for SSZ `ProgressiveList[ElementCodec]`.
pub fn ProgressiveListOf(comptime ElementCodec: type) type {
    return ListCodec(ElementCodec, 0, true);
}

fn ListCodec(comptime ElementCodec: type, comptime limit: comptime_int, comptime progressive: bool) type {
    comptime codec.assertCodec(ElementCodec);
    comptime schema_limit.assertValid(limit);
    if (!ElementCodec.is_variable_size and ElementCodec.fixed_size.? == 0) {
        @compileError("SSZ list elements cannot have zero encoded size");
    }
    const Element = ElementCodec.Value;
    const element_size = ElementCodec.fixed_size;

    return struct {
        pub const Value = []const Element;
        pub const Owned = []Element;
        pub const kind: codec.Kind = if (progressive) .progressive_list else .list;
        pub const element_codec = ElementCodec;
        pub const max_length: ?comptime_int = if (progressive) null else limit;
        pub const is_progressive = progressive;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = true;

        pub fn encodedLen(values: Value) Error!usize {
            try validateCount(values.len);
            if (ElementCodec.is_variable_size) {
                return sequence.encodedLen(ElementCodec, values);
            }
            const len = std.math.mul(usize, values.len, element_size.?) catch
                return error.EncodedLengthOverflow;
            try validateSerializedLength(len);
            return len;
        }

        pub fn encode(out: []u8, values: Value) Error![]u8 {
            const len = try encodedLen(values);
            if (out.len < len) return error.BufferTooSmall;

            if (ElementCodec.is_variable_size) {
                try sequence.encodeInto(ElementCodec, out[0..len], values);
            } else {
                for (values, 0..) |value, index| {
                    const start = index * element_size.?;
                    _ = try ElementCodec.encode(out[start .. start + element_size.?], value);
                }
            }
            return out[0..len];
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Value {
            const count = try decodedCount(bytes);
            const values = try allocator.alloc(Element, count);
            var initialized: usize = 0;
            errdefer {
                for (values[0..initialized]) |*value| codec.deinitOwned(ElementCodec, allocator, value);
                allocator.free(values);
            }

            if (comptime !ElementCodec.is_variable_size and
                !ElementCodec.requires_allocator and
                std.meta.hasFn(ElementCodec, "decodeFixedSequenceInto"))
            {
                try ElementCodec.decodeFixedSequenceInto(values, bytes);
                return values;
            }

            for (values, 0..) |*value, index| {
                const encoded = if (ElementCodec.is_variable_size)
                    sequence.elementBytes(bytes, count, index)
                else blk: {
                    const start = index * element_size.?;
                    break :blk bytes[start .. start + element_size.?];
                };
                value.* = try codec.decodeOwned(ElementCodec, allocator, encoded);
                initialized += 1;
            }
            return values;
        }

        pub fn validate(bytes: []const u8) Error!void {
            const count = try decodedCount(bytes);
            if (ElementCodec.is_variable_size) {
                for (0..count) |index| {
                    try ElementCodec.validate(sequence.elementBytes(bytes, count, index));
                }
            } else {
                for (0..count) |index| {
                    const start = index * element_size.?;
                    try ElementCodec.validate(bytes[start .. start + element_size.?]);
                }
            }
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            const owned: []Element = @constCast(value.*);
            for (owned) |*element| codec.deinitOwned(ElementCodec, allocator, element);
            allocator.free(owned);
            value.* = &.{};
        }

        fn decodedCount(bytes: []const u8) Error!usize {
            try validateSerializedLength(bytes.len);
            if (ElementCodec.is_variable_size) {
                const count = try sequence.inferCount(bytes);
                try validateCount(count);
                try sequence.validateOffsets(bytes, count);
                return count;
            }
            if (bytes.len % element_size.? != 0) return error.InvalidByteLength;
            const count = bytes.len / element_size.?;
            try validateCount(count);
            return count;
        }

        fn validateCount(count: usize) Error!void {
            if (!progressive and schema_limit.exceededBy(count, limit)) return error.ListLimitExceeded;
        }

        fn validateSerializedLength(len: usize) Error!void {
            if (len > std.math.maxInt(u32)) return error.EncodedLengthOverflow;
        }
    };
}

test "SSZ ListOf encodes variable elements with offsets" {
    const Bytes = ssz.ByteList(4);
    const ByteLists = ssz.ListOf(Bytes, 3);
    const values = [_][]const u8{ "ab", "", "c" };
    var storage: [15]u8 = undefined;

    const encoded = try ByteLists.encode(&storage, &values);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 12, 0, 0, 0, 14, 0, 0, 0, 14, 0, 0, 0, 'a', 'b', 'c' },
        encoded,
    );

    var decoded = try ByteLists.decodeAlloc(std.testing.allocator, encoded);
    defer ByteLists.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(usize, values.len), decoded.len);
    for (values, decoded) |expected, actual| {
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "SSZ ListOf composes variable containers" {
    const Item = struct {
        id: u16,
        data: []const u8,
    };
    const ItemSsz = ssz.Container(Item, .{ .data = ssz.ByteList(4) });
    const Items = ssz.ListOf(ItemSsz, 2);
    const values = [_]Item{
        .{ .id = 1, .data = "a" },
        .{ .id = 2, .data = "bc" },
    };
    var storage: [23]u8 = undefined;

    const encoded = try Items.encode(&storage, &values);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            8, 0, 0, 0, 15, 0,   0,   0,
            1, 0, 6, 0, 0,  0,   'a', 2,
            0, 6, 0, 0, 0,  'b', 'c',
        },
        encoded,
    );

    var decoded = try Items.decodeAlloc(std.testing.allocator, encoded);
    defer Items.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(usize, values.len), decoded.len);
    for (values, decoded) |expected, actual| {
        try std.testing.expectEqual(expected.id, actual.id);
        try std.testing.expectEqualSlices(u8, expected.data, actual.data);
    }
}

test "SSZ ListOf rejects malformed offsets and excess elements" {
    const ByteLists = ssz.ListOf(ssz.ByteList(4), 2);

    try std.testing.expectError(error.InvalidByteLength, ByteLists.validate(&.{1}));
    try std.testing.expectError(error.InvalidFirstOffset, ByteLists.validate(&.{ 5, 0, 0, 0, 0 }));
    try std.testing.expectError(error.OffsetOutOfBounds, ByteLists.validate(&.{ 8, 0, 0, 0 }));
    try std.testing.expectError(
        error.OffsetsNotMonotonic,
        ByteLists.validate(&.{ 8, 0, 0, 0, 7, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.ListLimitExceeded,
        ByteLists.validate(&.{ 12, 0, 0, 0, 12, 0, 0, 0, 12, 0, 0, 0 }),
    );
}

test "SSZ ProgressiveListOf reuses variable-element offset serialization" {
    const Values = ssz.ProgressiveListOf(ssz.ProgressiveByteList);
    const values = [_][]const u8{ "a", "bc" };
    var storage: [11]u8 = undefined;

    const encoded = try Values.encode(&storage, &values);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 8, 0, 0, 0, 9, 0, 0, 0, 'a', 'b', 'c' },
        encoded,
    );

    var decoded = try Values.decodeAlloc(std.testing.allocator, encoded);
    defer Values.deinit(std.testing.allocator, &decoded);
    for (values, decoded) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "SSZ ListOf composes fixed-size element codecs" {
    const Flags = ssz.Bitvector(4);
    const FlagsList = ssz.ListOf(Flags, 2);
    const values = [_][4]bool{
        .{ true, false, true, false },
        .{ false, true, false, true },
    };
    var storage: [2]u8 = undefined;

    const encoded = try FlagsList.encode(&storage, &values);
    try std.testing.expectEqualSlices(u8, &.{ 0b0000_0101, 0b0000_1010 }, encoded);
    var decoded: FlagsList.Value = try FlagsList.decodeAlloc(std.testing.allocator, encoded);
    defer FlagsList.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualDeep(values[0..], decoded);
}

test "SSZ ListOf keeps schema capacity independent from runtime count" {
    const Values = ssz.ListOf(ssz.Fixed(u16), 1 << 120);
    const values = [_]u16{ 1, 2 };
    var storage: [4]u8 = undefined;

    try std.testing.expect(comptime Values.max_length.? == 1 << 120);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, try Values.encode(&storage, &values));
}

test "SSZ ListOf dispatches fixed sequences through an optional codec capability" {
    const Specialized = struct {
        pub const Value = u16;
        pub const kind: codec.Kind = .basic;
        pub const is_variable_size = false;
        pub const fixed_size: ?usize = 2;
        pub const requires_allocator = false;
        pub var sequence_decode_calls: usize = 0;

        pub fn encodedLen(_: Value) Error!usize {
            return 2;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            if (out.len < 2) return error.BufferTooSmall;
            std.mem.writeInt(u16, out[0..2], value, .little);
            return out[0..2];
        }

        pub fn decode(bytes: []const u8) Error!Value {
            try validate(bytes);
            return std.mem.readInt(u16, bytes[0..2], .little);
        }

        pub fn validate(bytes: []const u8) Error!void {
            if (bytes.len != 2) return error.InvalidByteLength;
        }

        pub fn decodeFixedSequenceInto(out: []Value, bytes: []const u8) Error!void {
            sequence_decode_calls += 1;
            if (bytes.len != out.len * 2) return error.InvalidByteLength;
            for (out, 0..) |*value, index| {
                value.* = std.mem.readInt(u16, bytes[index * 2 ..][0..2], .little);
            }
        }
    };
    const Values = ssz.ListOf(Specialized, 4);
    Specialized.sequence_decode_calls = 0;

    var decoded = try Values.decodeAlloc(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0 });
    defer Values.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, decoded);
    try std.testing.expectEqual(@as(usize, 1), Specialized.sequence_decode_calls);
}
