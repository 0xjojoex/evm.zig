const std = @import("std");
const ssz = @import("lib.zig");
const Error = @import("error.zig").Error;

pub const Kind = enum {
    basic,
    vector,
    list,
    progressive_list,
    bitvector,
    bitlist,
    progressive_bitlist,
    container,
    progressive_container,
    union_type,
    compatible_union,
};

/// Validate the common interface implemented by composable SSZ codecs.
pub fn assertCodec(comptime Codec: type) void {
    inline for (.{ "Value", "kind", "is_variable_size", "fixed_size", "requires_allocator", "encodedLen", "encode", "validate" }) |decl| {
        if (!@hasDecl(Codec, decl)) @compileError("SSZ codec is missing " ++ decl);
    }
    if (@TypeOf(Codec.Value) != type) @compileError("SSZ codec Value must be a type");
    if (@TypeOf(Codec.kind) != Kind) @compileError("SSZ codec kind must be ssz.codec.Kind");
    if (@TypeOf(Codec.is_variable_size) != bool) @compileError("SSZ codec is_variable_size must be a bool");
    if (@TypeOf(Codec.fixed_size) != ?usize) @compileError("SSZ codec fixed_size must be ?usize");
    if (@TypeOf(Codec.requires_allocator) != bool) @compileError("SSZ codec requires_allocator must be a bool");
    if (Codec.is_variable_size == (Codec.fixed_size != null)) {
        @compileError("SSZ codec fixed_size must be null exactly when the codec is variable-size");
    }
    if (Codec.requires_allocator) {
        if (!std.meta.hasFn(Codec, "decodeAlloc")) @compileError("allocating SSZ codec is missing decodeAlloc");
        if (!std.meta.hasFn(Codec, "deinit")) @compileError("allocating SSZ codec is missing deinit");
    } else if (!std.meta.hasFn(Codec, "decode")) {
        @compileError("non-allocating SSZ codec is missing decode");
    }
    if (std.meta.hasFn(Codec, "decodeFixedSequenceInto")) {
        if (Codec.is_variable_size or Codec.requires_allocator) {
            @compileError("decodeFixedSequenceInto requires a fixed-size, non-allocating codec");
        }
        const Expected = fn ([]Codec.Value, []const u8) Error!void;
        if (@TypeOf(Codec.decodeFixedSequenceInto) != Expected) {
            @compileError("SSZ codec decodeFixedSequenceInto has an invalid signature");
        }
    }
}

/// Encode into a newly allocated exact-size buffer.
///
/// This is a top-level ownership adapter. Composable codecs must continue to
/// write directly into the caller-provided slices passed to `Codec.encode`.
pub fn encodeAlloc(
    comptime Codec: type,
    allocator: std.mem.Allocator,
    value: Codec.Value,
) (Error || std.mem.Allocator.Error)![]u8 {
    comptime assertCodec(Codec);
    const len = try Codec.encodedLen(value);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    const encoded = try Codec.encode(out, value);
    std.debug.assert(encoded.len == out.len);
    return out;
}

pub fn decodeOwned(
    comptime Codec: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (Error || std.mem.Allocator.Error)!Codec.Value {
    comptime assertCodec(Codec);
    return if (Codec.requires_allocator)
        Codec.decodeAlloc(allocator, bytes)
    else
        Codec.decode(bytes);
}

pub fn deinitOwned(comptime Codec: type, allocator: std.mem.Allocator, value: *Codec.Value) void {
    comptime assertCodec(Codec);
    if (Codec.requires_allocator) Codec.deinit(allocator, value);
}

test "SSZ encodeAlloc matches caller storage for fixed and variable codecs" {
    const FixedU64 = ssz.Fixed(u64);
    const fixed_value: u64 = 0x1122334455667788;
    var fixed_storage: [8]u8 = undefined;
    const fixed_direct = try FixedU64.encode(&fixed_storage, fixed_value);
    const fixed_owned = try ssz.encodeAlloc(FixedU64, std.testing.allocator, fixed_value);
    defer std.testing.allocator.free(fixed_owned);
    try std.testing.expectEqualSlices(u8, fixed_direct, fixed_owned);

    const Value = struct {
        count: u16,
        bytes: []const u8,
    };
    const ValueSsz = ssz.Container(Value, .{ .bytes = ssz.ByteList(8) });
    const value = Value{ .count = 3, .bytes = "abc" };
    var variable_storage: [9]u8 = undefined;
    const variable_direct = try ValueSsz.encode(&variable_storage, value);
    const variable_owned = try ssz.encodeAlloc(ValueSsz, std.testing.allocator, value);
    defer std.testing.allocator.free(variable_owned);
    try std.testing.expectEqualSlices(u8, variable_direct, variable_owned);
}

test "SSZ encodeAlloc releases output after every failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const Bytes = ssz.ByteList(8);
            const encoded = try ssz.encodeAlloc(Bytes, allocator, "abc");
            defer allocator.free(encoded);
            try std.testing.expectEqualSlices(u8, "abc", encoded);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});

    const FailingCodec = struct {
        pub const Value = u8;
        pub const kind = @import("codec.zig").Kind.basic;
        pub const is_variable_size = false;
        pub const fixed_size: ?usize = 1;
        pub const requires_allocator = false;

        pub fn encodedLen(_: Value) ssz.Error!usize {
            return 1;
        }

        pub fn encode(_: []u8, _: Value) ssz.Error![]u8 {
            return error.InvalidBoolean;
        }

        pub fn decode(bytes: []const u8) ssz.Error!Value {
            try validate(bytes);
            return bytes[0];
        }

        pub fn validate(bytes: []const u8) ssz.Error!void {
            if (bytes.len != 1) return error.InvalidByteLength;
        }
    };
    try std.testing.expectError(
        error.InvalidBoolean,
        ssz.encodeAlloc(FailingCodec, std.testing.allocator, 1),
    );
}
