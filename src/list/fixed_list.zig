const std = @import("std");
const ssz = @import("../lib.zig");
const builtin = @import("builtin");
const codec = @import("../codec.zig");
const fixed = @import("../basic/fixed.zig");
const Error = @import("../error.zig").Error;
const eager = @import("../basic/eager.zig");
const schema_limit = @import("../schema_limit.zig");

/// Return the codec for SSZ `List[FixedT, limit]`.
/// `limit` is an arbitrary-precision schema capacity; runtime lengths remain `usize`.
pub fn List(comptime T: type, comptime limit: comptime_int) type {
    return ListCodec(T, limit, false);
}

/// Return the codec for SSZ `ProgressiveList[FixedT]`.
pub fn ProgressiveList(comptime T: type) type {
    return ListCodec(T, 0, true);
}

fn ListCodec(comptime T: type, comptime limit: comptime_int, comptime progressive: bool) type {
    comptime schema_limit.assertValid(limit);
    const element_size = eager.encodedSize(T);
    const direct_wire_layout = hasDirectWireLayout(T);

    return struct {
        pub const Value = []const T;
        pub const Owned = []T;
        pub const Element = T;
        pub const kind: codec.Kind = if (progressive) .progressive_list else .list;
        pub const element_codec = fixed.Fixed(T);
        pub const max_length: ?comptime_int = if (progressive) null else limit;
        pub const is_progressive = progressive;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = true;

        pub fn encodedLen(values: Value) Error!usize {
            try validateCount(values.len);
            const len = std.math.mul(usize, values.len, element_size) catch
                return error.EncodedLengthOverflow;
            try validateSerializedLength(len);
            return len;
        }

        pub fn encode(out: []u8, values: Value) Error![]u8 {
            const len = try encodedLen(values);
            if (out.len < len) return error.BufferTooSmall;

            if (comptime direct_wire_layout) {
                @memcpy(out[0..len], std.mem.sliceAsBytes(values));
            } else {
                for (values, 0..) |value, index| {
                    const start = index * element_size;
                    const target: *[element_size]u8 = @ptrCast(out[start..].ptr);
                    eager.encodeInto(target, value);
                }
            }
            return out[0..len];
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Value {
            const count = try decodedCount(bytes);

            const values = try allocator.alloc(T, count);
            errdefer allocator.free(values);
            if (comptime direct_wire_layout) {
                @memcpy(std.mem.sliceAsBytes(values), bytes);
            } else {
                for (values, 0..) |*value, index| {
                    const start = index * element_size;
                    const encoded: *const [element_size]u8 = @ptrCast(bytes[start..].ptr);
                    value.* = try eager.decode(T, encoded);
                }
            }
            return values;
        }

        pub fn validate(bytes: []const u8) Error!void {
            const count = try decodedCount(bytes);
            if (comptime direct_wire_layout) return;

            for (0..count) |index| {
                const start = index * element_size;
                const encoded: *const [element_size]u8 = @ptrCast(bytes[start..].ptr);
                _ = try eager.decode(T, encoded);
            }
        }

        fn decodedCount(bytes: []const u8) Error!usize {
            try validateSerializedLength(bytes.len);
            if (bytes.len % element_size != 0) return error.InvalidByteLength;
            const count = bytes.len / element_size;
            try validateCount(count);
            return count;
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            allocator.free(value.*);
            value.* = &.{};
        }

        fn validateCount(count: usize) Error!void {
            if (!progressive and schema_limit.exceededBy(count, limit)) return error.ListLimitExceeded;
        }

        fn validateSerializedLength(len: usize) Error!void {
            if (len > std.math.maxInt(u32)) return error.EncodedLengthOverflow;
        }
    };
}

/// Whether native contiguous memory is already canonical SSZ wire bytes.
fn hasDirectWireLayout(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |int| int.bits == 8 or builtin.target.cpu.arch.endian() == .little,
        .array => |array| hasDirectWireLayout(array.child),
        else => false,
    };
}

test "SSZ List of fixed structs encodes and materializes decoded elements" {
    const Withdrawal = struct {
        index: u64,
        amount: u16,
        active: bool,
    };
    const Withdrawals = ssz.List(Withdrawal, 4);
    const values = [_]Withdrawal{
        .{ .index = 1, .amount = 2, .active = true },
        .{ .index = 3, .amount = 4, .active = false },
    };
    var storage: [22]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 22), try Withdrawals.encodedLen(&values));
    const encoded = try Withdrawals.encode(&storage, &values);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1,
            3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0,
        },
        encoded,
    );

    const decoded = try Withdrawals.decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualDeep(values, decoded[0..values.len].*);
}

test "SSZ List accepts empty and exact-limit values" {
    const Values = ssz.List(u16, 2);
    const empty = [_]u16{};
    const exact = [_]u16{ 7, 9 };
    var storage: [4]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), (try Values.encode(&storage, &empty)).len);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 9, 0 }, try Values.encode(&storage, &exact));

    const decoded_empty = try Values.decodeAlloc(std.testing.allocator, "");
    defer std.testing.allocator.free(decoded_empty);
    try std.testing.expectEqual(@as(usize, 0), decoded_empty.len);
}

test "SSZ List keeps schema capacity independent from runtime count" {
    const Values = ssz.List(u16, 1 << 120);
    const values = [_]u16{ 1, 2 };
    var storage: [4]u8 = undefined;

    try std.testing.expect(comptime Values.max_length.? == 1 << 120);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, try Values.encode(&storage, &values));
}

test "SSZ List preserves direct-wire byte-vector elements" {
    const Values = ssz.List([4]u8, 2);
    const values = [_][4]u8{ "abcd".*, "wxyz".* };
    var storage: [8]u8 = undefined;

    const encoded = try Values.encode(&storage, &values);
    try std.testing.expectEqualStrings("abcdwxyz", encoded);

    const decoded = try Values.decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices([4]u8, &values, decoded);
}

test "SSZ List rejects malformed length, excess elements, and short output" {
    const Values = ssz.List(u16, 2);
    const too_many = [_]u16{ 1, 2, 3 };
    const two = [_]u16{ 1, 2 };
    var short_storage: [3]u8 = undefined;
    var enough_storage: [6]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, Values.encode(&short_storage, &two));
    try std.testing.expectError(error.ListLimitExceeded, Values.encode(&enough_storage, &too_many));
    try std.testing.expectError(error.InvalidByteLength, Values.decodeAlloc(std.testing.allocator, &.{1}));
    try std.testing.expectError(error.ListLimitExceeded, Values.decodeAlloc(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0 }));
}

test "SSZ List propagates nested fixed decode errors" {
    const Value = struct { active: bool };
    const Values = ssz.List(Value, 1);

    try std.testing.expectError(error.InvalidBoolean, Values.decodeAlloc(std.testing.allocator, &.{2}));
}

test "SSZ ProgressiveList reuses fixed-element serialization without a schema limit" {
    const Values = ssz.ProgressiveList(u16);
    const values = [_]u16{ 1, 2, 3 };
    var storage: [6]u8 = undefined;

    try std.testing.expect(Values.is_progressive);
    try std.testing.expectEqual(@as(?comptime_int, null), Values.max_length);
    const encoded = try Values.encode(&storage, &values);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0 }, encoded);

    const decoded = try Values.decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u16, &values, decoded);
}
