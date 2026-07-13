const std = @import("std");
const ssz = @import("../lib.zig");
const compatibility = @import("../compatibility.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;
const fixed = @import("../basic/fixed.zig");
const int_enum = @import("../basic/int_enum.zig");
const optional_union = @import("../union/optional_union.zig");
const variable_vector = @import("../vector/variable_vector.zig");

const bytes_per_offset = 4;

/// Return the codec for an SSZ container.
///
/// Field codecs resolve in this order: an explicit override, the field type's
/// `Ssz` declaration, then `codecFor(FieldType)`.
pub fn Container(comptime T: type, comptime overrides: anytype) type {
    // Nested generated consensus schemas exceed Zig's default 1,000-branch
    // quota even for modest field counts; the work depends on child schemas,
    // so a field-count formula would provide false precision.
    // To avoid exceeding the quota on caller side, try set a higher quota wrap with comptime
    // ```
    // comptime {
    //      @setEvalBranchQuota(20_000);
    //      Ssz.Container(@This(), .{});
    //  }
    // ```
    @setEvalBranchQuota(10_000);
    comptime validateSchema(T, overrides);
    const fixed_section_size = comptime fixedSectionSize(T, overrides);

    const Common = struct {
        pub const Value = T;
        pub const kind: codec.Kind = .container;
        pub const field_overrides = overrides;
        pub const is_variable_size = hasVariableFields(T, overrides);
        pub const fixed_size: ?usize = if (is_variable_size) null else fixed_section_size;
        pub const requires_allocator = hasAllocatingFields(T, overrides);

        pub fn encodedLen(value: T) Error!usize {
            var total = fixed_section_size;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const FieldSsz = fieldCodec(overrides, field.name, field.type);
                if (FieldSsz.is_variable_size) {
                    total = std.math.add(usize, total, try FieldSsz.encodedLen(@field(value, field.name))) catch
                        return error.EncodedLengthOverflow;
                } else {
                    _ = try FieldSsz.encodedLen(@field(value, field.name));
                }
            }
            try validateSerializedLength(total);
            return total;
        }

        pub fn encode(out: []u8, value: T) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;

            var fixed_offset: usize = 0;
            var variable_offset = fixed_section_size;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const FieldSsz = fieldCodec(overrides, field.name, field.type);
                if (FieldSsz.is_variable_size) {
                    writeOffset(out[fixed_offset..][0..bytes_per_offset], variable_offset);
                    fixed_offset += bytes_per_offset;
                    const encoded = try FieldSsz.encode(
                        out[variable_offset..len],
                        @field(value, field.name),
                    );
                    variable_offset += encoded.len;
                } else {
                    const field_size = FieldSsz.fixed_size.?;
                    _ = try FieldSsz.encode(out[fixed_offset..][0..field_size], @field(value, field.name));
                    fixed_offset += field_size;
                }
            }
            std.debug.assert(variable_offset == len);
            return out[0..len];
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!T {
            try validateLayout(T, overrides, bytes);
            var value: T = undefined;
            try decodeFields(T, overrides, allocator, bytes, &value, 0);
            return value;
        }

        pub fn decode(bytes: []const u8) Error!T {
            try validateLayout(T, overrides, bytes);
            var value: T = undefined;
            try decodeFieldsNoAlloc(T, overrides, bytes, &value, 0);
            return value;
        }

        pub fn decodeFixedSequenceInto(out: []T, bytes: []const u8) Error!void {
            const expected = std.math.mul(usize, out.len, fixed_section_size) catch
                return error.EncodedLengthOverflow;
            if (bytes.len != expected) return error.InvalidByteLength;

            for (out, 0..) |*value, index| {
                const start = index * fixed_section_size;
                try decodeFieldsNoAlloc(
                    T,
                    overrides,
                    bytes[start..][0..fixed_section_size],
                    value,
                    0,
                );
            }
        }

        pub fn validate(bytes: []const u8) Error!void {
            try validateLayout(T, overrides, bytes);

            inline for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
                const FieldSsz = fieldCodec(overrides, field.name, field.type);
                if (FieldSsz.is_variable_size) {
                    try FieldSsz.validate(try variableFieldBytes(T, overrides, bytes, index));
                } else {
                    const start = comptime fieldFixedOffset(T, overrides, index);
                    try FieldSsz.validate(bytes[start..][0..FieldSsz.fixed_size.?]);
                }
            }
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *T) void {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const FieldSsz = fieldCodec(overrides, field.name, field.type);
                codec.deinitOwned(FieldSsz, allocator, &@field(value, field.name));
            }
        }

        pub fn FieldCodec(comptime name: []const u8, comptime Field: type) type {
            return fieldCodec(overrides, name, Field);
        }
    };

    if (Common.requires_allocator) {
        return struct {
            pub const Value = Common.Value;
            pub const kind = Common.kind;
            pub const field_overrides = Common.field_overrides;
            pub const is_variable_size = Common.is_variable_size;
            pub const fixed_size = Common.fixed_size;
            pub const requires_allocator = true;
            pub const encodedLen = Common.encodedLen;
            pub const encode = Common.encode;
            pub const decodeAlloc = Common.decodeAlloc;
            pub const validate = Common.validate;
            pub const deinit = Common.deinit;
            pub const FieldCodec = Common.FieldCodec;
        };
    }
    if (Common.is_variable_size) return struct {
        pub const Value = Common.Value;
        pub const kind = Common.kind;
        pub const field_overrides = Common.field_overrides;
        pub const is_variable_size = Common.is_variable_size;
        pub const fixed_size = Common.fixed_size;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encode = Common.encode;
        pub const decode = Common.decode;
        pub const validate = Common.validate;
        pub const FieldCodec = Common.FieldCodec;
    };
    return struct {
        pub const Value = Common.Value;
        pub const kind = Common.kind;
        pub const field_overrides = Common.field_overrides;
        pub const is_variable_size = Common.is_variable_size;
        pub const fixed_size = Common.fixed_size;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encode = Common.encode;
        pub const decode = Common.decode;
        pub const decodeFixedSequenceInto = Common.decodeFixedSequenceInto;
        pub const validate = Common.validate;
        pub const FieldCodec = Common.FieldCodec;
    };
}

test "SSZ composite encode does not premeasure variable children while writing" {
    const Counting = struct {
        pub const Value = u8;
        pub const kind: codec.Kind = .list;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = false;
        pub var encoded_len_calls: usize = 0;

        pub fn encodedLen(_: Value) Error!usize {
            encoded_len_calls += 1;
            return 1;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            if (out.len < 1) return error.BufferTooSmall;
            out[0] = value;
            return out[0..1];
        }

        pub fn decode(bytes: []const u8) Error!Value {
            try validate(bytes);
            return bytes[0];
        }

        pub fn validate(bytes: []const u8) Error!void {
            if (bytes.len != 1) return error.InvalidByteLength;
        }
    };
    const Values = @import("../list/variable_list.zig").ListOf(Counting, 2);
    const Box = struct { values: Values.Value };
    const BoxSsz = Container(Box, .{ .values = Values });
    const values = [_]u8{ 1, 2 };
    var out: [14]u8 = undefined;
    Counting.encoded_len_calls = 0;

    _ = try BoxSsz.encode(&out, .{ .values = &values });

    // One list sizing pass from the container and one from the list encoder.
    try std.testing.expectEqual(@as(usize, 4), Counting.encoded_len_calls);
}

fn validateLayout(comptime T: type, comptime overrides: anytype, bytes: []const u8) Error!void {
    const fixed_section_size = comptime fixedSectionSize(T, overrides);
    try validateSerializedLength(bytes.len);
    if (bytes.len < fixed_section_size) return error.InvalidByteLength;
    if (comptime !hasVariableFields(T, overrides)) {
        if (bytes.len != fixed_section_size) return error.InvalidByteLength;
        return;
    }
    try validateOffsets(T, overrides, bytes);
}

fn validateSchema(comptime T: type, comptime overrides: anytype) void {
    const structure = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => @compileError("SSZ Container requires a Zig struct"),
    };
    if (structure.is_tuple) @compileError("SSZ Container does not support tuples");
    if (structure.fields.len == 0) @compileError("SSZ containers cannot be empty");

    inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |override| {
        if (!@hasField(T, override.name)) @compileError("unknown SSZ container override field: " ++ override.name);
        if (override.type != type) @compileError("SSZ container overrides must be codec types");
    }

    inline for (structure.fields) |field| {
        if (field.is_comptime) @compileError("SSZ containers cannot contain comptime fields");
        const FieldCodec = fieldCodec(overrides, field.name, field.type);
        codec.assertCodec(FieldCodec);
        if (FieldCodec.Value != field.type) {
            @compileError("SSZ field codec Value does not match field type: " ++ field.name);
        }
    }
}

fn decodeFields(
    comptime T: type,
    comptime overrides: anytype,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    value: *T,
    comptime index: usize,
) (Error || std.mem.Allocator.Error)!void {
    const fields = @typeInfo(T).@"struct".fields;
    if (index == fields.len) return;
    const field = fields[index];

    const FieldCodec = fieldCodec(overrides, field.name, field.type);
    const encoded = if (FieldCodec.is_variable_size)
        try variableFieldBytes(T, overrides, bytes, index)
    else blk: {
        const start = comptime fieldFixedOffset(T, overrides, index);
        break :blk bytes[start..][0..FieldCodec.fixed_size.?];
    };
    @field(value, field.name) = try codec.decodeOwned(FieldCodec, allocator, encoded);
    errdefer codec.deinitOwned(FieldCodec, allocator, &@field(value, field.name));
    return decodeFields(T, overrides, allocator, bytes, value, index + 1);
}

fn decodeFieldsNoAlloc(
    comptime T: type,
    comptime overrides: anytype,
    bytes: []const u8,
    value: *T,
    comptime index: usize,
) Error!void {
    const fields = @typeInfo(T).@"struct".fields;
    if (index == fields.len) return;
    const field = fields[index];
    const FieldCodec = fieldCodec(overrides, field.name, field.type);
    if (FieldCodec.requires_allocator) unreachable;
    const encoded = if (FieldCodec.is_variable_size)
        try variableFieldBytes(T, overrides, bytes, index)
    else blk: {
        const start = comptime fieldFixedOffset(T, overrides, index);
        break :blk bytes[start..][0..FieldCodec.fixed_size.?];
    };
    @field(value, field.name) = try FieldCodec.decode(encoded);
    return decodeFieldsNoAlloc(T, overrides, bytes, value, index + 1);
}

fn validateOffsets(comptime T: type, comptime overrides: anytype, bytes: []const u8) Error!void {
    const expected_first = comptime fixedSectionSize(T, overrides);
    var previous = expected_first;
    var saw_variable = false;

    inline for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
        if (comptime fieldCodec(overrides, field.name, field.type).is_variable_size) {
            const offset = readOffset(bytes, comptime fieldFixedOffset(T, overrides, index));
            if (!saw_variable and offset != expected_first) return error.InvalidFirstOffset;
            if (offset < previous) return error.OffsetsNotMonotonic;
            if (offset > bytes.len) return error.OffsetOutOfBounds;
            previous = offset;
            saw_variable = true;
        }
    }
}

fn variableFieldBytes(
    comptime T: type,
    comptime overrides: anytype,
    bytes: []const u8,
    comptime index: usize,
) Error![]const u8 {
    const fields = @typeInfo(T).@"struct".fields;
    const start = readOffset(bytes, comptime fieldFixedOffset(T, overrides, index));
    var end = bytes.len;
    inline for (fields[index + 1 ..], index + 1..) |field, later_index| {
        if (comptime fieldCodec(overrides, field.name, field.type).is_variable_size) {
            end = readOffset(bytes, comptime fieldFixedOffset(T, overrides, later_index));
            break;
        }
    }
    if (start > end) return error.OffsetsNotMonotonic;
    if (end > bytes.len) return error.OffsetOutOfBounds;
    return bytes[start..end];
}

fn fixedSectionSize(comptime T: type, comptime overrides: anytype) usize {
    comptime var total: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const FieldCodec = fieldCodec(overrides, field.name, field.type);
        total += if (FieldCodec.is_variable_size) bytes_per_offset else FieldCodec.fixed_size.?;
    }
    return total;
}

fn fieldFixedOffset(comptime T: type, comptime overrides: anytype, comptime target: usize) usize {
    @setEvalBranchQuota(10_000);
    comptime var total: usize = 0;
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
        if (index == target) return total;
        const FieldCodec = fieldCodec(overrides, field.name, field.type);
        total += if (FieldCodec.is_variable_size) bytes_per_offset else FieldCodec.fixed_size.?;
    }
    unreachable;
}

fn hasVariableFields(comptime T: type, comptime overrides: anytype) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (fieldCodec(overrides, field.name, field.type).is_variable_size) return true;
    }
    return false;
}

fn hasAllocatingFields(comptime T: type, comptime overrides: anytype) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (fieldCodec(overrides, field.name, field.type).requires_allocator) return true;
    }
    return false;
}

fn hasOverride(comptime overrides: anytype, comptime name: []const u8) bool {
    return @hasField(@TypeOf(overrides), name);
}

fn fieldCodec(comptime overrides: anytype, comptime name: []const u8, comptime T: type) type {
    if (hasOverride(overrides, name)) return @field(overrides, name);
    return codecFor(T);
}

/// Infer the canonical SSZ codec for an unambiguous Zig host type.
///
/// Slices, bitfields, tagged unions, pointers, and other representation choices
/// require an explicit codec because their Zig type does not carry enough SSZ
/// schema information.
pub fn codecFor(comptime T: type) type {
    if (hasEmbeddedCodec(T)) return T.Ssz;

    return switch (@typeInfo(T)) {
        .bool, .int => fixed.Fixed(T),
        .@"enum" => int_enum.IntEnum(T),
        .array => |array| blk: {
            if (array.len == 0) @compileError("SSZ vectors cannot be empty");
            if (canUseEagerFixed(T)) break :blk fixed.Fixed(T);
            break :blk variable_vector.VectorOf(codecFor(array.child), array.len);
        },
        .@"struct" => Container(T, .{}),
        .optional => |optional| optional_union.OptionalUnion(codecFor(optional.child)),
        .pointer => |pointer| if (pointer.size == .slice)
            @compileError("SSZ cannot infer a bound for slice type " ++ @typeName(T) ++ "; provide a field override or type-owned Ssz codec")
        else
            @compileError("SSZ cannot infer pointer type " ++ @typeName(T) ++ "; provide a field override or type-owned Ssz codec"),
        .@"union" => @compileError("SSZ tagged unions require an explicit Union or CompatibleUnion codec for " ++ @typeName(T)),
        else => @compileError("SSZ cannot infer a codec for " ++ @typeName(T) ++ "; provide a field override or type-owned Ssz codec"),
    };
}

fn hasEmbeddedCodec(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "Ssz"),
        else => false,
    };
}

fn canUseEagerFixed(comptime T: type) bool {
    if (hasEmbeddedCodec(T)) return false;
    return switch (@typeInfo(T)) {
        .bool => true,
        .int => true,
        .array => |array| array.len != 0 and canUseEagerFixed(array.child),
        .@"struct" => |structure| blk: {
            if (structure.is_tuple or structure.fields.len == 0) break :blk false;
            inline for (structure.fields) |field| {
                if (field.is_comptime or !canUseEagerFixed(field.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn writeOffset(out: []u8, offset: usize) void {
    std.mem.writeInt(u32, out[0..bytes_per_offset], @intCast(offset), .little);
}

fn readOffset(bytes: []const u8, offset: usize) usize {
    return std.mem.readInt(u32, bytes[offset..][0..bytes_per_offset], .little);
}

fn validateSerializedLength(len: usize) Error!void {
    if (len > std.math.maxInt(u32)) return error.EncodedLengthOverflow;
}

test "SSZ codecFor maps enums and optionals without field overrides" {
    const Mode = enum(u16) {
        inactive = 0,
        active = 7,
    };
    const Child = struct {
        value: u16,
    };
    const Value = struct {
        mode: Mode,
        limit: ?u64,
        pair: [2]u16,
        child: Child,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    const value = Value{
        .mode = .active,
        .limit = 42,
        .pair = .{ 1, 2 },
        .child = .{ .value = 0x1234 },
    };
    var storage: [21]u8 = undefined;

    const encoded = try Value.Ssz.encode(&storage, value);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            7,    0,
            12,   0,
            0,    0,
            1,    0,
            2,    0,
            0x34, 0x12,
            1,    42,
            0,    0,
            0,    0,
            0,    0,
            0,
        },
        encoded,
    );
    try std.testing.expectEqualDeep(value, try Value.Ssz.decode(encoded));

    var invalid_enum = storage;
    invalid_enum[0] = 1;
    try std.testing.expectError(error.InvalidEnumValue, Value.Ssz.decode(&invalid_enum));

    var invalid_selector = storage;
    invalid_selector[12] = 2;
    try std.testing.expectError(error.InvalidUnionSelector, Value.Ssz.decode(&invalid_selector));
}

test "SSZ inferred optional uses canonical Union None semantics" {
    const Choice = union(enum) {
        none: void,
        value: u64,
    };
    const ChoiceSsz = ssz.Union(Choice, .{ .none = ssz.None });
    const OptionalSsz = ssz.codecFor(?u64);
    var storage: [9]u8 = undefined;

    try std.testing.expect(compatibility.compatible(OptionalSsz, ssz.codecFor(?u64)));
    try std.testing.expectEqualSlices(u8, &.{0}, try OptionalSsz.encode(&storage, null));
    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 42, 0, 0, 0, 0, 0, 0, 0 },
        try OptionalSsz.encode(&storage, 42),
    );
    try std.testing.expectEqual(@as(?u64, null), try OptionalSsz.decode(&.{0}));
    try std.testing.expectEqual(@as(?u64, 42), try OptionalSsz.decode(&storage));
    try std.testing.expectError(error.InvalidByteLength, OptionalSsz.decode(""));
    try std.testing.expectError(error.InvalidByteLength, OptionalSsz.decode(&.{ 0, 0 }));
    try std.testing.expectError(error.InvalidUnionSelector, OptionalSsz.decode(&.{2}));
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(ChoiceSsz, .{ .none = {} }),
        try ssz.hashTreeRoot(OptionalSsz, null),
    );
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(ChoiceSsz, .{ .value = 42 }),
        try ssz.hashTreeRoot(OptionalSsz, 42),
    );
}

test "SSZ inferred optional propagates child ownership" {
    const Message = struct {
        bytes: []const u8,

        pub const Ssz = ssz.Container(@This(), .{
            .bytes = ssz.ByteList(8),
        });
    };
    const OptionalMessage = ssz.codecFor(?Message);
    const value: ?Message = .{ .bytes = "hello" };
    var storage: [10]u8 = undefined;

    try std.testing.expect(OptionalMessage.requires_allocator);
    const encoded = try OptionalMessage.encode(&storage, value);
    var decoded = try OptionalMessage.decodeAlloc(std.testing.allocator, encoded);
    defer OptionalMessage.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualStrings("hello", decoded.?.bytes);
}

test "SSZ codecFor composes variable arrays of plain structs" {
    const Item = struct {
        value: ?u16,
    };
    const Envelope = struct {
        items: [2]Item,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    const value = Envelope{
        .items = .{
            .{ .value = null },
            .{ .value = 0x1234 },
        },
    };
    var storage: [24]u8 = undefined;

    try std.testing.expect(Envelope.Ssz.is_variable_size);
    try std.testing.expect(!Envelope.Ssz.requires_allocator);
    const encoded = try Envelope.Ssz.encode(&storage, value);
    try std.testing.expectEqualDeep(value, try Envelope.Ssz.decode(encoded));
    _ = try ssz.hashTreeRoot(Envelope.Ssz, value);
}

test "SSZ Container infers embedded child schemas without allocation" {
    const Child = struct {
        value: u16,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    const Parent = struct {
        child: Child,
        root: [32]u8,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    const value = Parent{ .child = .{ .value = 0x1234 }, .root = @splat(0xab) };
    var encoded: [34]u8 = undefined;

    try std.testing.expect(!Parent.Ssz.requires_allocator);
    try std.testing.expect(@hasDecl(Parent.Ssz, "decode"));
    try std.testing.expect(!@hasDecl(Parent.Ssz, "decodeAlloc"));
    _ = try Parent.Ssz.encode(&encoded, value);
    try std.testing.expectEqualDeep(value, try Parent.Ssz.decode(&encoded));
}

test "SSZ fixed Container decodes a sequence with one outer length check" {
    const Item = struct {
        count: u16,
        active: bool,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    var decoded: [2]Item = undefined;

    try std.testing.expect(std.meta.hasFn(Item.Ssz, "decodeFixedSequenceInto"));
    try Item.Ssz.decodeFixedSequenceInto(&decoded, &.{ 1, 0, 1, 2, 0, 0 });
    try std.testing.expectEqualDeep(
        [_]Item{ .{ .count = 1, .active = true }, .{ .count = 2, .active = false } },
        decoded,
    );
    try std.testing.expectError(
        error.InvalidByteLength,
        Item.Ssz.decodeFixedSequenceInto(&decoded, &.{ 1, 0, 1 }),
    );
    try std.testing.expectError(
        error.InvalidBoolean,
        Item.Ssz.decodeFixedSequenceInto(&decoded, &.{ 1, 0, 2, 2, 0, 0 }),
    );
}
