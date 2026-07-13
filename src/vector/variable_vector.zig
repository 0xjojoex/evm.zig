const std = @import("std");
const ssz = @import("../lib.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;
const sequence = @import("../variable_sequence.zig");

/// Return the codec for SSZ `Vector[ElementCodec, length]`.
pub fn VectorOf(comptime ElementCodec: type, comptime vector_length: usize) type {
    comptime codec.assertCodec(ElementCodec);
    if (!ElementCodec.is_variable_size and ElementCodec.fixed_size.? == 0) {
        @compileError("SSZ vector elements cannot have zero encoded size");
    }
    if (vector_length == 0) @compileError("SSZ vectors cannot be empty");
    const Element = ElementCodec.Value;
    const element_size = ElementCodec.fixed_size;

    const Common = struct {
        pub const Value = [vector_length]Element;
        pub const kind: codec.Kind = .vector;
        pub const element_codec = ElementCodec;
        pub const length = vector_length;
        pub const is_variable_size = ElementCodec.is_variable_size;
        pub const fixed_size: ?usize = if (is_variable_size)
            null
        else
            vector_length * element_size.?;
        pub const requires_allocator = ElementCodec.requires_allocator;

        pub fn encodedLen(value: Value) Error!usize {
            if (ElementCodec.is_variable_size) {
                return sequence.encodedLen(ElementCodec, &value);
            }
            return fixed_size.?;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;
            if (ElementCodec.is_variable_size) {
                try sequence.encodeInto(ElementCodec, out[0..len], &value);
            } else {
                for (value, 0..) |element, index| {
                    const start = index * element_size.?;
                    _ = try ElementCodec.encode(out[start .. start + element_size.?], element);
                }
            }
            return out[0..len];
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Value {
            try validateLayout(bytes);
            var value: Value = undefined;
            var initialized: usize = 0;
            errdefer {
                for (value[0..initialized]) |*element| codec.deinitOwned(ElementCodec, allocator, element);
            }

            for (&value, 0..) |*element, index| {
                const encoded = if (ElementCodec.is_variable_size)
                    sequence.elementBytes(bytes, vector_length, index)
                else blk: {
                    const start = index * element_size.?;
                    break :blk bytes[start .. start + element_size.?];
                };
                element.* = try codec.decodeOwned(ElementCodec, allocator, encoded);
                initialized += 1;
            }
            return value;
        }

        pub fn decode(bytes: []const u8) Error!Value {
            try validateLayout(bytes);
            var value: Value = undefined;
            for (&value, 0..) |*element, index| {
                const encoded = if (ElementCodec.is_variable_size)
                    sequence.elementBytes(bytes, vector_length, index)
                else blk: {
                    const start = index * element_size.?;
                    break :blk bytes[start .. start + element_size.?];
                };
                element.* = try ElementCodec.decode(encoded);
            }
            return value;
        }

        pub fn validate(bytes: []const u8) Error!void {
            try validateLayout(bytes);
            if (ElementCodec.is_variable_size) {
                for (0..vector_length) |index| {
                    try ElementCodec.validate(sequence.elementBytes(bytes, vector_length, index));
                }
            } else {
                for (0..vector_length) |index| {
                    const start = index * element_size.?;
                    try ElementCodec.validate(bytes[start .. start + element_size.?]);
                }
            }
        }

        fn validateLayout(bytes: []const u8) Error!void {
            if (ElementCodec.is_variable_size) {
                try sequence.validateOffsets(bytes, vector_length);
            } else if (bytes.len != fixed_size.?) {
                return error.InvalidByteLength;
            }
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            for (value) |*element| codec.deinitOwned(ElementCodec, allocator, element);
        }
    };

    if (Common.requires_allocator) {
        return struct {
            pub const Value = Common.Value;
            pub const kind = Common.kind;
            pub const element_codec = Common.element_codec;
            pub const length = Common.length;
            pub const is_variable_size = Common.is_variable_size;
            pub const fixed_size = Common.fixed_size;
            pub const requires_allocator = true;
            pub const encodedLen = Common.encodedLen;
            pub const encode = Common.encode;
            pub const decodeAlloc = Common.decodeAlloc;
            pub const validate = Common.validate;
            pub const deinit = Common.deinit;
        };
    }
    return struct {
        pub const Value = Common.Value;
        pub const kind = Common.kind;
        pub const element_codec = Common.element_codec;
        pub const length = Common.length;
        pub const is_variable_size = Common.is_variable_size;
        pub const fixed_size = Common.fixed_size;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encode = Common.encode;
        pub const decode = Common.decode;
        pub const validate = Common.validate;
    };
}

/// Return an allocation-backed SSZ vector codec with an exact runtime slice.
///
/// This preserves fixed vector semantics without placing very large vectors
/// inline in a containing Zig struct.
pub fn VectorSliceOf(comptime ElementCodec: type, comptime vector_length: usize) type {
    comptime codec.assertCodec(ElementCodec);
    if (!ElementCodec.is_variable_size and ElementCodec.fixed_size.? == 0) {
        @compileError("SSZ vector elements cannot have zero encoded size");
    }
    if (vector_length == 0) @compileError("SSZ vectors cannot be empty");
    const Element = ElementCodec.Value;
    const element_size = ElementCodec.fixed_size;

    return struct {
        pub const Value = []const Element;
        pub const Owned = []Element;
        pub const kind: codec.Kind = .vector;
        pub const element_codec = ElementCodec;
        pub const length = vector_length;
        pub const is_variable_size = ElementCodec.is_variable_size;
        pub const fixed_size: ?usize = if (is_variable_size)
            null
        else
            vector_length * element_size.?;
        pub const requires_allocator = true;

        pub fn encodedLen(values: Value) Error!usize {
            try validateCount(values.len);
            if (ElementCodec.is_variable_size) {
                return sequence.encodedLen(ElementCodec, values);
            }
            return fixed_size.?;
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
            try validateLayout(bytes);
            const values = try allocator.alloc(Element, vector_length);
            var initialized: usize = 0;
            errdefer {
                for (values[0..initialized]) |*value| codec.deinitOwned(ElementCodec, allocator, value);
                allocator.free(values);
            }

            for (values, 0..) |*value, index| {
                const encoded = if (ElementCodec.is_variable_size)
                    sequence.elementBytes(bytes, vector_length, index)
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
            try validateLayout(bytes);
            if (ElementCodec.is_variable_size) {
                for (0..vector_length) |index| {
                    try ElementCodec.validate(sequence.elementBytes(bytes, vector_length, index));
                }
            } else {
                for (0..vector_length) |index| {
                    const start = index * element_size.?;
                    try ElementCodec.validate(bytes[start .. start + element_size.?]);
                }
            }
        }

        fn validateLayout(bytes: []const u8) Error!void {
            if (ElementCodec.is_variable_size) {
                try sequence.validateOffsets(bytes, vector_length);
            } else if (bytes.len != fixed_size.?) {
                return error.InvalidByteLength;
            }
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            const owned: []Element = @constCast(value.*);
            for (owned) |*element| codec.deinitOwned(ElementCodec, allocator, element);
            allocator.free(owned);
            value.* = &.{};
        }

        fn validateCount(count: usize) Error!void {
            if (count != vector_length) return error.InvalidByteLength;
        }
    };
}

test "SSZ VectorOf encodes its declared number of variable elements" {
    const Pair = ssz.VectorOf(ssz.ByteList(4), 2);
    const value = [2][]const u8{ "ab", "c" };
    var storage: [11]u8 = undefined;

    const encoded = try Pair.encode(&storage, value);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 8, 0, 0, 0, 10, 0, 0, 0, 'a', 'b', 'c' },
        encoded,
    );

    var decoded = try Pair.decodeAlloc(std.testing.allocator, encoded);
    defer Pair.deinit(std.testing.allocator, &decoded);
    for (value, decoded) |expected, actual| {
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "SSZ VectorOf retains offsets when every element is empty" {
    const Pair = ssz.VectorOf(ssz.ByteList(4), 2);
    const value = [2][]const u8{ "", "" };
    var storage: [8]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &.{ 8, 0, 0, 0, 8, 0, 0, 0 },
        try Pair.encode(&storage, value),
    );
}

test "SSZ VectorOf composes explicit fixed element codecs" {
    const Pair = ssz.VectorOf(ssz.Fixed(u16), 2);
    const value = [2]u16{ 0x1122, 0x3344 };
    var storage: [4]u8 = undefined;

    try std.testing.expect(!Pair.is_variable_size);
    try std.testing.expectEqual(@as(?usize, 4), Pair.fixed_size);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x22, 0x11, 0x44, 0x33 },
        try Pair.encode(&storage, value),
    );
    try std.testing.expect(!Pair.requires_allocator);
    try std.testing.expectEqualDeep(value, try Pair.decode(&storage));
}

test "SSZ VectorSliceOf materializes exact fixed-count vectors on the heap" {
    const Pair = ssz.VectorSliceOf(ssz.Fixed(u16), 2);
    const value = [_]u16{ 0x1122, 0x3344 };
    var storage: [4]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x22, 0x11, 0x44, 0x33 },
        try Pair.encode(&storage, &value),
    );
    var decoded = try Pair.decodeAlloc(std.testing.allocator, &storage);
    defer Pair.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualSlices(u16, &value, decoded);
    try std.testing.expectError(error.InvalidByteLength, Pair.encode(&storage, value[0..1]));
}

test "SSZ VectorOf enforces its declared count and child validity" {
    const Pair = ssz.VectorOf(ssz.ByteList(1), 2);

    try std.testing.expectError(error.InvalidByteLength, Pair.validate(&.{ 8, 0, 0, 0 }));
    try std.testing.expectError(
        error.InvalidFirstOffset,
        Pair.validate(&.{ 4, 0, 0, 0, 4, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.ListLimitExceeded,
        Pair.validate(&.{ 8, 0, 0, 0, 10, 0, 0, 0, 'a', 'b', 'c' }),
    );
}
