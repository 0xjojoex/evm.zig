const std = @import("std");
const ssz = @import("../lib.zig");
const codec = @import("../codec.zig");
const compatibility = @import("../compatibility.zig");
const Error = @import("../error.zig").Error;
const container = @import("../container/typed_container.zig");

/// Return the codec for an SSZ `CompatibleUnion({selector: type})`.
pub fn CompatibleUnion(comptime T: type, comptime config: anytype) type {
    comptime validateSchema(T, config);
    const fields = @typeInfo(T).@"union".fields;
    const Tag = @typeInfo(T).@"union".tag_type.?;

    const Common = struct {
        pub const Value = T;
        pub const kind: codec.Kind = .compatible_union;
        pub const union_options = config;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = hasAllocatingOptions(fields, config);

        pub fn encodedLen(value: T) Error!usize {
            const active = std.meta.activeTag(value);
            inline for (fields) |field| {
                if (active == @field(Tag, field.name)) {
                    const Codec = optionCodec(config, field.name, field.type);
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
            inline for (fields) |field| {
                if (active == @field(Tag, field.name)) {
                    out[0] = selectorOf(@field(config, field.name));
                    const Codec = optionCodec(config, field.name, field.type);
                    _ = try Codec.encode(out[1..len], @field(value, field.name));
                    return out[0..len];
                }
            }
            unreachable;
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!T {
            const selector = try validateSelector(bytes);
            inline for (fields) |field| {
                if (selector == selectorOf(@field(config, field.name))) {
                    const Codec = optionCodec(config, field.name, field.type);
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
            inline for (fields) |field| {
                if (selector == selectorOf(@field(config, field.name))) {
                    const Codec = optionCodec(config, field.name, field.type);
                    return @unionInit(T, field.name, try Codec.decode(bytes[1..]));
                }
            }
            unreachable;
        }

        pub fn validate(bytes: []const u8) Error!void {
            const selector = try validateSelector(bytes);
            inline for (fields) |field| {
                if (selector == selectorOf(@field(config, field.name))) {
                    const Codec = optionCodec(config, field.name, field.type);
                    try Codec.validate(bytes[1..]);
                    return;
                }
            }
            unreachable;
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *T) void {
            const active = std.meta.activeTag(value.*);
            inline for (fields) |field| {
                if (active == @field(Tag, field.name)) {
                    const Codec = optionCodec(config, field.name, field.type);
                    codec.deinitOwned(Codec, allocator, &@field(value, field.name));
                    return;
                }
            }
            unreachable;
        }

        pub fn OptionCodec(comptime name: []const u8, comptime Option: type) type {
            return optionCodec(config, name, Option);
        }

        fn validateSelector(bytes: []const u8) Error!u8 {
            if (bytes.len == 0) return error.InvalidByteLength;
            const selector = bytes[0];
            inline for (fields) |field| {
                if (selector == selectorOf(@field(config, field.name))) return selector;
            }
            return error.InvalidUnionSelector;
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

fn validateSchema(comptime T: type, comptime config: anytype) void {
    const union_info = switch (@typeInfo(T)) {
        .@"union" => |value| value,
        else => @compileError("SSZ CompatibleUnion requires a Zig union(enum)"),
    };
    if (union_info.tag_type == null) @compileError("SSZ CompatibleUnion requires a tagged Zig union");
    if (union_info.fields.len == 0) @compileError("SSZ CompatibleUnion requires at least one option");

    const config_fields = switch (@typeInfo(@TypeOf(config))) {
        .@"struct" => |value| value.fields,
        else => @compileError("SSZ CompatibleUnion config must be a struct"),
    };
    if (config_fields.len != union_info.fields.len) {
        @compileError("SSZ CompatibleUnion requires one config entry per union field");
    }

    inline for (config_fields) |entry| {
        if (!@hasField(T, entry.name)) @compileError("unknown SSZ CompatibleUnion option: " ++ entry.name);
        validateEntry(@field(config, entry.name));
    }

    inline for (union_info.fields, 0..) |field, index| {
        if (!@hasField(@TypeOf(config), field.name)) {
            @compileError("missing SSZ CompatibleUnion option: " ++ field.name);
        }
        const Codec = optionCodec(config, field.name, field.type);
        codec.assertCodec(Codec);
        if (Codec.Value != field.type) {
            @compileError("SSZ CompatibleUnion codec Value does not match option field: " ++ field.name);
        }

        inline for (union_info.fields[index + 1 ..]) |later| {
            if (selectorOf(@field(config, field.name)) == selectorOf(@field(config, later.name))) {
                @compileError("SSZ CompatibleUnion selectors must be unique");
            }
            if (!compatibility.compatible(Codec, optionCodec(config, later.name, later.type))) {
                @compileError("SSZ CompatibleUnion options must have compatible Merkleization");
            }
        }
    }
}

fn validateEntry(comptime entry: anytype) void {
    const fields = switch (@typeInfo(@TypeOf(entry))) {
        .@"struct" => |value| value.fields,
        else => @compileError("SSZ CompatibleUnion entries must be structs"),
    };
    if (!@hasField(@TypeOf(entry), "selector")) {
        @compileError("SSZ CompatibleUnion entry is missing selector");
    }
    inline for (fields) |field| {
        if (!std.mem.eql(u8, field.name, "selector") and !std.mem.eql(u8, field.name, "codec")) {
            @compileError("unknown SSZ CompatibleUnion entry field: " ++ field.name);
        }
    }
    if (@hasField(@TypeOf(entry), "codec") and @TypeOf(entry.codec) != type) {
        @compileError("SSZ CompatibleUnion entry codec must be a type");
    }
    _ = selectorOf(entry);
}

fn selectorOf(comptime entry: anytype) u8 {
    const selector = entry.selector;
    switch (@typeInfo(@TypeOf(selector))) {
        .comptime_int, .int => {},
        else => @compileError("SSZ CompatibleUnion selector must be an integer"),
    }
    if (selector < 1 or selector > 127) {
        @compileError("SSZ CompatibleUnion selectors must be between 1 and 127");
    }
    return @intCast(selector);
}

fn optionCodec(comptime config: anytype, comptime name: []const u8, comptime T: type) type {
    const entry = @field(config, name);
    return if (@hasField(@TypeOf(entry), "codec")) entry.codec else container.codecFor(T);
}

fn hasAllocatingOptions(comptime fields: anytype, comptime config: anytype) bool {
    inline for (fields) |field| {
        if (optionCodec(config, field.name, field.type).requires_allocator) return true;
    }
    return false;
}

test "SSZ CompatibleUnion uses explicit sparse selectors" {
    const Choice = union(enum) {
        primary: u16,
        secondary: u16,
    };
    const ChoiceSsz = ssz.CompatibleUnion(Choice, .{
        .primary = .{ .selector = 1 },
        .secondary = .{ .selector = 7 },
    });
    var storage: [3]u8 = undefined;

    const encoded = try ChoiceSsz.encode(&storage, .{ .secondary = 0x1234 });
    try std.testing.expectEqualSlices(u8, &.{ 7, 0x34, 0x12 }, encoded);
    const decoded = try ChoiceSsz.decode(encoded);
    try std.testing.expectEqual(@as(u16, 0x1234), decoded.secondary);
    try std.testing.expectError(error.InvalidUnionSelector, ChoiceSsz.validate(&.{ 2, 0, 0 }));
}

test "SSZ CompatibleUnion accepts compatible ProgressiveContainer options" {
    const Square = struct {
        side: u16,
        color: u8,
    };
    const Circle = struct {
        radius: u16,
        color: u8,
    };
    const SquareSsz = ssz.ProgressiveContainer(
        Square,
        [_]bool{ true, false, true },
        .{},
    );
    const CircleSsz = ssz.ProgressiveContainer(
        Circle,
        [_]bool{ false, true, true },
        .{},
    );
    const Shape = union(enum) {
        square: Square,
        circle: Circle,
    };
    const ShapeSsz = ssz.CompatibleUnion(Shape, .{
        .square = .{ .selector = 1, .codec = SquareSsz },
        .circle = .{ .selector = 2, .codec = CircleSsz },
    });
    var storage: [4]u8 = undefined;
    const value = Shape{ .circle = .{ .radius = 0x1122, .color = 0x33 } };

    const encoded = try ShapeSsz.encode(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0x22, 0x11, 0x33 }, encoded);
    const decoded = try ShapeSsz.decode(encoded);
    try std.testing.expectEqualDeep(value, decoded);
}
