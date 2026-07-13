const std = @import("std");
const ssz = @import("../lib.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;
const container = @import("../container/typed_container.zig");

/// Marker for the optional first `None` alternative of an SSZ union.
pub const None = struct {};

/// Return the codec for an SSZ union represented by a Zig tagged union.
///
/// Zig union field declaration order defines the serialized selector values.
pub fn Union(comptime T: type, comptime overrides: anytype) type {
    comptime validateSchema(T, overrides);
    const fields = @typeInfo(T).@"union".fields;
    const Tag = @typeInfo(T).@"union".tag_type.?;

    const Common = struct {
        pub const Value = T;
        pub const kind: codec.Kind = .union_type;
        pub const union_options = overrides;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = hasAllocatingOptions(fields, overrides);

        pub fn encodedLen(value: T) Error!usize {
            const active = std.meta.activeTag(value);
            inline for (fields) |field| {
                if (active == @field(Tag, field.name)) {
                    const Codec = fieldCodec(overrides, field.name, field.type);
                    if (comptime isNone(Codec)) return 1;
                    return std.math.add(usize, 1, try Codec.encodedLen(@field(value, field.name))) catch
                        error.EncodedLengthOverflow;
                }
            }
            unreachable;
        }

        pub fn encode(out: []u8, value: T) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;

            const active = std.meta.activeTag(value);
            inline for (fields, 0..) |field, selector| {
                if (active == @field(Tag, field.name)) {
                    out[0] = @intCast(selector);
                    const Codec = fieldCodec(overrides, field.name, field.type);
                    if (comptime !isNone(Codec)) {
                        _ = try Codec.encode(out[1..len], @field(value, field.name));
                    }
                    return out[0..len];
                }
            }
            unreachable;
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!T {
            const selector = try validateSelector(bytes);
            inline for (fields, 0..) |field, index| {
                if (selector == index) {
                    const Codec = fieldCodec(overrides, field.name, field.type);
                    if (comptime isNone(Codec)) {
                        if (bytes.len != 1) return error.InvalidByteLength;
                        return @unionInit(T, field.name, {});
                    }
                    return @unionInit(
                        T,
                        field.name,
                        try codec.decodeOwned(Codec, allocator, bytes[1..]),
                    );
                }
            }
            unreachable;
        }

        pub fn decode(bytes: []const u8) Error!T {
            const selector = try validateSelector(bytes);
            inline for (fields, 0..) |field, index| {
                if (selector == index) {
                    const Codec = fieldCodec(overrides, field.name, field.type);
                    if (comptime isNone(Codec)) {
                        if (bytes.len != 1) return error.InvalidByteLength;
                        return @unionInit(T, field.name, {});
                    }
                    return @unionInit(T, field.name, try Codec.decode(bytes[1..]));
                }
            }
            unreachable;
        }

        pub fn validate(bytes: []const u8) Error!void {
            const selector = try validateSelector(bytes);

            inline for (fields, 0..) |field, index| {
                if (selector == index) {
                    const Codec = fieldCodec(overrides, field.name, field.type);
                    if (comptime isNone(Codec)) {
                        if (bytes.len != 1) return error.InvalidByteLength;
                    } else {
                        try Codec.validate(bytes[1..]);
                    }
                    return;
                }
            }
            unreachable;
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *T) void {
            const active = std.meta.activeTag(value.*);
            inline for (fields) |field| {
                if (active == @field(Tag, field.name)) {
                    const Codec = fieldCodec(overrides, field.name, field.type);
                    if (comptime !isNone(Codec)) {
                        codec.deinitOwned(Codec, allocator, &@field(value, field.name));
                    }
                    return;
                }
            }
            unreachable;
        }

        pub fn OptionCodec(comptime name: []const u8, comptime Option: type) type {
            return fieldCodec(overrides, name, Option);
        }

        fn validateSelector(bytes: []const u8) Error!u8 {
            if (bytes.len == 0) return error.InvalidByteLength;
            const selector = bytes[0];
            if (selector >= fields.len) return error.InvalidUnionSelector;
            return selector;
        }
    };

    if (Common.requires_allocator) {
        return struct {
            pub const Value = Common.Value;
            pub const kind = Common.kind;
            pub const union_options = Common.union_options;
            pub const is_variable_size = Common.is_variable_size;
            pub const fixed_size = Common.fixed_size;
            pub const requires_allocator = true;
            pub const encodedLen = Common.encodedLen;
            pub const encode = Common.encode;
            pub const decodeAlloc = Common.decodeAlloc;
            pub const validate = Common.validate;
            pub const deinit = Common.deinit;
            pub const OptionCodec = Common.OptionCodec;
        };
    }
    return struct {
        pub const Value = Common.Value;
        pub const kind = Common.kind;
        pub const union_options = Common.union_options;
        pub const is_variable_size = Common.is_variable_size;
        pub const fixed_size = Common.fixed_size;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encode = Common.encode;
        pub const decode = Common.decode;
        pub const validate = Common.validate;
        pub const OptionCodec = Common.OptionCodec;
    };
}

fn validateSchema(comptime T: type, comptime overrides: anytype) void {
    const union_info = switch (@typeInfo(T)) {
        .@"union" => |value| value,
        else => @compileError("SSZ Union requires a Zig union(enum)"),
    };
    if (union_info.tag_type == null) @compileError("SSZ Union requires a tagged Zig union");
    if (union_info.fields.len == 0) @compileError("SSZ unions require at least one option");
    if (union_info.fields.len > 128) @compileError("SSZ unions support selectors 0 through 127");

    const override_fields = switch (@typeInfo(@TypeOf(overrides))) {
        .@"struct" => |value| value.fields,
        else => @compileError("SSZ Union overrides must be a struct of codec types"),
    };

    inline for (override_fields) |override| {
        if (!@hasField(T, override.name)) @compileError("unknown SSZ Union override: " ++ override.name);
        if (override.type != type) @compileError("SSZ Union overrides must be codec types");
    }
    inline for (union_info.fields, 0..) |field, index| {
        const Codec = fieldCodec(overrides, field.name, field.type);
        if (comptime isNone(Codec)) {
            if (index != 0) @compileError("SSZ None is legal only as the first Union option");
            if (union_info.fields.len < 2) @compileError("SSZ Union with None requires another option");
            if (field.type != void) @compileError("SSZ None option must use a void union field");
        } else {
            codec.assertCodec(Codec);
            if (Codec.Value != field.type) {
                @compileError("SSZ Union codec Value does not match option field: " ++ field.name);
            }
        }
    }
}

fn isNone(comptime Codec: type) bool {
    return Codec == None;
}

fn hasAllocatingOptions(comptime fields: anytype, comptime overrides: anytype) bool {
    inline for (fields) |field| {
        const Codec = fieldCodec(overrides, field.name, field.type);
        if (!isNone(Codec) and Codec.requires_allocator) return true;
    }
    return false;
}

fn fieldCodec(comptime overrides: anytype, comptime name: []const u8, comptime T: type) type {
    return if (@hasField(@TypeOf(overrides), name))
        @field(overrides, name)
    else
        container.codecFor(T);
}

test "SSZ unions infer enum option codecs" {
    const Mode = enum(u64) {
        inactive = 0,
        active = 7,
    };
    const Choice = union(enum) {
        mode: Mode,
        number: u64,
    };
    const ChoiceSsz = ssz.Union(Choice, .{});
    const CompatibleChoiceSsz = ssz.CompatibleUnion(Choice, .{
        .mode = .{ .selector = 1 },
        .number = .{ .selector = 2 },
    });
    var storage: [9]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 7, 0, 0, 0, 0, 0, 0, 0 },
        try ChoiceSsz.encode(&storage, .{ .mode = .active }),
    );
    try std.testing.expectEqualDeep(
        Choice{ .mode = .active },
        try ChoiceSsz.decode(&storage),
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 7, 0, 0, 0, 0, 0, 0, 0 },
        try CompatibleChoiceSsz.encode(&storage, .{ .mode = .active }),
    );
    try std.testing.expectEqualDeep(
        Choice{ .mode = .active },
        try CompatibleChoiceSsz.decode(&storage),
    );
}

test "SSZ Union prefixes fixed and variable alternatives with selectors" {
    const Choice = union(enum) {
        number: u16,
        bytes: []const u8,
    };
    const ChoiceSsz = ssz.Union(Choice, .{
        .bytes = ssz.ByteList(4),
    });
    var storage: [5]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0x34, 0x12 },
        try ChoiceSsz.encode(&storage, .{ .number = 0x1234 }),
    );
    const encoded_bytes = try ChoiceSsz.encode(&storage, .{ .bytes = "ab" });
    try std.testing.expectEqualSlices(u8, &.{ 1, 'a', 'b' }, encoded_bytes);

    var decoded = try ChoiceSsz.decodeAlloc(std.testing.allocator, encoded_bytes);
    defer ChoiceSsz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualStrings("ab", decoded.bytes);
}

test "SSZ Union supports None only as an empty first alternative" {
    const Optional = union(enum) {
        none: void,
        enabled: bool,
    };
    const OptionalSsz = ssz.Union(Optional, .{
        .none = ssz.None,
    });
    var storage: [2]u8 = undefined;

    try std.testing.expectEqualSlices(u8, &.{0}, try OptionalSsz.encode(&storage, .{ .none = {} }));
    try std.testing.expectEqualSlices(u8, &.{ 1, 1 }, try OptionalSsz.encode(&storage, .{ .enabled = true }));
    try std.testing.expect(!OptionalSsz.requires_allocator);
    try std.testing.expectEqual(.none, std.meta.activeTag(try OptionalSsz.decode(&.{0})));
}

test "SSZ Union rejects invalid selectors and malformed selected values" {
    const Optional = union(enum) {
        none: void,
        enabled: bool,
    };
    const OptionalSsz = ssz.Union(Optional, .{
        .none = ssz.None,
    });

    try std.testing.expectError(error.InvalidByteLength, OptionalSsz.validate(""));
    try std.testing.expectError(error.InvalidUnionSelector, OptionalSsz.validate(&.{2}));
    try std.testing.expectError(error.InvalidByteLength, OptionalSsz.validate(&.{ 0, 0 }));
    try std.testing.expectError(error.InvalidBoolean, OptionalSsz.validate(&.{ 1, 2 }));
}
