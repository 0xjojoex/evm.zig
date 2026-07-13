const std = @import("std");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;

/// Represent canonical SSZ `Union[None, T]` as Zig `?T`.
pub fn OptionalUnion(comptime ValueCodec: type) type {
    comptime codec.assertCodec(ValueCodec);

    const Common = struct {
        pub const Value = ?ValueCodec.Value;
        pub const kind: codec.Kind = .union_type;
        pub const value_codec = ValueCodec;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = ValueCodec.requires_allocator;

        pub fn encodedLen(value: Value) Error!usize {
            const payload_len = if (value) |payload| try ValueCodec.encodedLen(payload) else 0;
            return std.math.add(usize, 1, payload_len) catch error.EncodedLengthOverflow;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;

            if (value) |payload| {
                out[0] = 1;
                _ = try ValueCodec.encode(out[1..len], payload);
            } else {
                out[0] = 0;
            }
            return out[0..len];
        }

        pub fn decodeAlloc(
            allocator: std.mem.Allocator,
            bytes: []const u8,
        ) (Error || std.mem.Allocator.Error)!Value {
            try validateSelector(bytes);
            return switch (bytes[0]) {
                0 => null,
                1 => try codec.decodeOwned(ValueCodec, allocator, bytes[1..]),
                else => unreachable,
            };
        }

        pub fn decode(bytes: []const u8) Error!Value {
            try validateSelector(bytes);
            return switch (bytes[0]) {
                0 => null,
                1 => try ValueCodec.decode(bytes[1..]),
                else => unreachable,
            };
        }

        pub fn validate(bytes: []const u8) Error!void {
            try validateSelector(bytes);
            if (bytes[0] == 1) try ValueCodec.validate(bytes[1..]);
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            if (value.*) |*payload| codec.deinitOwned(ValueCodec, allocator, payload);
        }

        fn validateSelector(bytes: []const u8) Error!void {
            if (bytes.len == 0) return error.InvalidByteLength;
            switch (bytes[0]) {
                0 => if (bytes.len != 1) return error.InvalidByteLength,
                1 => {},
                else => return error.InvalidUnionSelector,
            }
        }
    };

    if (Common.requires_allocator) {
        return struct {
            pub const Value = Common.Value;
            pub const kind = Common.kind;
            pub const value_codec = Common.value_codec;
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
        pub const value_codec = Common.value_codec;
        pub const is_variable_size = Common.is_variable_size;
        pub const fixed_size = Common.fixed_size;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encode = Common.encode;
        pub const decode = Common.decode;
        pub const validate = Common.validate;
    };
}
