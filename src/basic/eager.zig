//! Eager SSZ codec for unambiguous fixed-size Zig values.
//!
//! Supported values are SSZ unsigned integers, booleans, non-empty arrays of
//! supported values, and non-empty structs whose fields are all
//! supported. Variable and ambiguous shapes are rejected at comptime.

const std = @import("std");
const ssz = @import("../lib.zig");

pub const Error = @import("../error.zig").Error;

/// Return the canonical SSZ byte length of a fixed-size Zig type.
pub fn encodedSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |int| blk: {
            validateInteger(int);
            break :blk int.bits / 8;
        },
        .array => |array| blk: {
            if (array.len == 0) @compileError("SSZ vectors cannot be empty");
            const element_size = comptime encodedSize(array.child);
            const size = comptime array.len * element_size;
            if (size > std.math.maxInt(u32)) @compileError("SSZ encoded size exceeds the 32-bit offset range");
            break :blk size;
        },
        .@"struct" => |structure| blk: {
            validateStruct(structure);
            comptime var total: usize = 0;
            inline for (structure.fields) |field| {
                total += comptime encodedSize(field.type);
            }
            if (total > std.math.maxInt(u32)) @compileError("SSZ encoded size exceeds the 32-bit offset range");
            break :blk total;
        },
        else => @compileError("SSZ fixed codec supports only unsigned integers, booleans, arrays, and structs"),
    };
}

/// Encode a fixed-size value into an exactly-sized byte array.
pub fn encode(value: anytype) [encodedSize(@TypeOf(value))]u8 {
    const T = @TypeOf(value);
    var out: [encodedSize(T)]u8 = undefined;
    encodeInto(&out, value);
    return out;
}

/// Encode a fixed-size value directly into an exactly-sized destination.
pub fn encodeInto(out: anytype, value: anytype) void {
    const T = @TypeOf(value);
    const Destination = *[encodedSize(T)]u8;
    if (@TypeOf(out) != Destination) {
        @compileError("SSZ fixed encodeInto requires *[encodedSize(T)]u8 destination");
    }
    encodeValue(T, out, value);
}

/// Decode an exactly-sized byte array into a fixed-size Zig value.
pub fn decode(comptime T: type, bytes: *const [encodedSize(T)]u8) Error!T {
    return decodeValue(T, bytes);
}

/// Decode a runtime slice after checking its byte length.
pub fn decodeSlice(comptime T: type, bytes: []const u8) Error!T {
    const size = comptime encodedSize(T);
    if (bytes.len != size) return error.InvalidByteLength;
    const exact: *const [size]u8 = @ptrCast(bytes.ptr);
    return decode(T, exact);
}

fn validateInteger(comptime int: std.builtin.Type.Int) void {
    if (int.signedness != .unsigned) @compileError("SSZ integers must be unsigned");
    if (int.bits != 8 and int.bits != 16 and int.bits != 32 and int.bits != 64 and int.bits != 128 and int.bits != 256) {
        @compileError("SSZ integer width must be 8, 16, 32, 64, 128, or 256 bits");
    }
}

fn validateStruct(comptime structure: std.builtin.Type.Struct) void {
    if (structure.is_tuple) @compileError("SSZ fixed structs cannot be tuples");
    if (structure.fields.len == 0) @compileError("SSZ containers cannot be empty");
    inline for (structure.fields) |field| {
        if (field.is_comptime) @compileError("SSZ fixed structs cannot contain comptime fields");
    }
}

fn encodeValue(comptime T: type, out: []u8, value: T) void {
    switch (@typeInfo(T)) {
        .bool => out[0] = @intFromBool(value),
        .int => {
            const target: *[encodedSize(T)]u8 = @ptrCast(out.ptr);
            std.mem.writeInt(T, target, value, .little);
        },
        .array => |array| {
            const element_size = encodedSize(array.child);
            for (value, 0..) |element, index| {
                encodeValue(
                    array.child,
                    out[index * element_size ..][0..element_size],
                    element,
                );
            }
        },
        .@"struct" => |structure| {
            comptime var offset: usize = 0;
            inline for (structure.fields) |field| {
                const field_size = comptime encodedSize(field.type);
                encodeValue(
                    field.type,
                    out[offset..][0..field_size],
                    @field(value, field.name),
                );
                offset += field_size;
            }
        },
        else => unreachable,
    }
}

fn decodeValue(comptime T: type, bytes: []const u8) Error!T {
    return switch (@typeInfo(T)) {
        .bool => switch (bytes[0]) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        },
        .int => blk: {
            const source: *const [encodedSize(T)]u8 = @ptrCast(bytes.ptr);
            break :blk std.mem.readInt(T, source, .little);
        },
        .array => |array| blk: {
            var value: T = undefined;
            const element_size = encodedSize(array.child);
            for (&value, 0..) |*element, index| {
                element.* = try decodeValue(
                    array.child,
                    bytes[index * element_size ..][0..element_size],
                );
            }
            break :blk value;
        },
        .@"struct" => |structure| blk: {
            var value: T = undefined;
            comptime var offset: usize = 0;
            inline for (structure.fields) |field| {
                const field_size = comptime encodedSize(field.type);
                @field(value, field.name) = try decodeValue(
                    field.type,
                    bytes[offset..][0..field_size],
                );
                offset += field_size;
            }
            break :blk value;
        },
        else => unreachable,
    };
}

test "SSZ fixed basics encode little-endian and decode by value" {
    const value: u64 = 0x1122334455667788;
    const encoded = ssz.encode(value);

    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, &encoded);
    try std.testing.expectEqual(value, try ssz.decode(u64, &encoded));
}

test "SSZ fixed encodeInto writes directly into caller storage" {
    var encoded: [4]u8 = undefined;
    ssz.encodeInto(&encoded, @as(u32, 0x11223344));

    try std.testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11 }, &encoded);
}

test "SSZ fixed boolean decode enforces canonical bytes" {
    const encoded_true = ssz.encode(true);
    try std.testing.expectEqualSlices(u8, &.{1}, &encoded_true);
    try std.testing.expect(try ssz.decode(bool, &encoded_true));

    const invalid = [_]u8{2};
    try std.testing.expectError(error.InvalidBoolean, ssz.decode(bool, &invalid));
}

test "SSZ fixed arrays encode elements consecutively" {
    const value = [_]u16{ 0x1122, 0x3344, 0x5566 };
    const encoded = ssz.encode(value);

    try std.testing.expectEqual(@as(usize, 6), ssz.encodedSize(@TypeOf(value)));
    try std.testing.expectEqualSlices(u8, &.{ 0x22, 0x11, 0x44, 0x33, 0x66, 0x55 }, &encoded);
    try std.testing.expectEqualDeep(value, try ssz.decode(@TypeOf(value), &encoded));
}

test "SSZ fixed nested structs round-trip without using Zig memory layout" {
    const Point = struct {
        x: u16,
        y: u32,
    };
    const Envelope = struct {
        active: bool,
        points: [2]Point,
        digest: [4]u8,
    };
    const value = Envelope{
        .active = true,
        .points = .{
            .{ .x = 0x1122, .y = 0x33445566 },
            .{ .x = 0x7788, .y = 0x99aabbcc },
        },
        .digest = .{ 0xde, 0xad, 0xbe, 0xef },
    };

    try std.testing.expectEqual(@as(usize, 17), ssz.encodedSize(Envelope));
    const encoded = ssz.encode(value);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            1,
            0x22,
            0x11,
            0x66,
            0x55,
            0x44,
            0x33,
            0x88,
            0x77,
            0xcc,
            0xbb,
            0xaa,
            0x99,
            0xde,
            0xad,
            0xbe,
            0xef,
        },
        &encoded,
    );
    try std.testing.expectEqualDeep(value, try ssz.decode(Envelope, &encoded));
}

test "SSZ fixed nested boolean decode remains canonical" {
    const Value = struct {
        count: u16,
        active: bool,
    };
    const invalid = [_]u8{ 7, 0, 2 };

    try std.testing.expectError(error.InvalidBoolean, ssz.decode(Value, &invalid));
}

test "SSZ fixed codec supports uint256" {
    const value: u256 = (@as(u256, 1) << 255) | 0x1234;
    const encoded = ssz.encode(value);

    try std.testing.expectEqual(@as(u8, 0x34), encoded[0]);
    try std.testing.expectEqual(@as(u8, 0x12), encoded[1]);
    try std.testing.expectEqual(@as(u8, 0x80), encoded[31]);
    try std.testing.expectEqual(value, try ssz.decode(u256, &encoded));
}

test "SSZ decodeSlice checks runtime byte length" {
    const encoded = ssz.encode(@as(u32, 7));
    try std.testing.expectEqual(@as(u32, 7), try ssz.decodeSlice(u32, &encoded));
    try std.testing.expectError(error.InvalidByteLength, ssz.decodeSlice(u32, encoded[0..3]));
}
