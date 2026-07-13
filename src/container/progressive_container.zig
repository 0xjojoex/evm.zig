const std = @import("std");
const ssz = @import("../lib.zig");
const codec = @import("../codec.zig");
const container = @import("typed_container.zig");
const Error = @import("../error.zig").Error;

/// Return the codec for an SSZ `ProgressiveContainer(active_fields)`.
///
/// `active_fields` is static Merkleization metadata and is not serialized.
pub fn ProgressiveContainer(comptime T: type, comptime active_config: anytype, comptime overrides: anytype) type {
    comptime validateActiveFields(T, active_config);
    const Base = container.Container(T, overrides);

    if (Base.requires_allocator) {
        return struct {
            pub const Value = T;
            pub const kind: codec.Kind = .progressive_container;
            pub const active_fields = active_config;
            pub const field_overrides = overrides;
            pub const is_progressive = true;
            pub const is_variable_size = Base.is_variable_size;
            pub const fixed_size = Base.fixed_size;
            pub const requires_allocator = true;
            pub const encodedLen = Base.encodedLen;
            pub const encode = Base.encode;
            pub const decodeAlloc = Base.decodeAlloc;
            pub const validate = Base.validate;
            pub const deinit = Base.deinit;
            pub const FieldCodec = Base.FieldCodec;
        };
    }
    return struct {
        pub const Value = T;
        pub const kind: codec.Kind = .progressive_container;
        pub const active_fields = active_config;
        pub const field_overrides = overrides;
        pub const is_progressive = true;
        pub const is_variable_size = Base.is_variable_size;
        pub const fixed_size = Base.fixed_size;
        pub const requires_allocator = false;
        pub const encodedLen = Base.encodedLen;
        pub const encode = Base.encode;
        pub const decode = Base.decode;
        pub const validate = Base.validate;
        pub const FieldCodec = Base.FieldCodec;
    };
}

fn validateActiveFields(comptime T: type, comptime active_fields: anytype) void {
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |value| value.fields,
        else => @compileError("SSZ ProgressiveContainer requires a Zig struct"),
    };
    const active = switch (@typeInfo(@TypeOf(active_fields))) {
        .array => |value| value,
        else => @compileError("SSZ ProgressiveContainer active_fields must be a bool array"),
    };
    if (active.child != bool) @compileError("SSZ ProgressiveContainer active_fields must be a bool array");
    if (active.len == 0) @compileError("SSZ ProgressiveContainer active_fields cannot be empty");
    if (active.len > 256) @compileError("SSZ ProgressiveContainer active_fields cannot exceed 256 bits");
    if (!active_fields[active.len - 1]) @compileError("SSZ ProgressiveContainer active_fields must end in an active bit");

    comptime var active_count: usize = 0;
    inline for (active_fields) |is_active| {
        if (is_active) active_count += 1;
    }
    if (active_count != fields.len) {
        @compileError("SSZ ProgressiveContainer requires one active bit per field");
    }
}

test "SSZ ProgressiveContainer retains active fields without serializing them" {
    const Square = struct {
        side: u16,
        color: u8,
    };
    const SquareSsz = ssz.ProgressiveContainer(
        Square,
        [_]bool{ true, false, true },
        .{},
    );
    const value = Square{ .side = 0x1122, .color = 0x33 };
    var storage: [3]u8 = undefined;

    try std.testing.expect(SquareSsz.is_progressive);
    try std.testing.expect(!SquareSsz.is_variable_size);
    try std.testing.expectEqual(@as(?usize, 3), SquareSsz.fixed_size);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, &SquareSsz.active_fields);
    const encoded = try SquareSsz.encode(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{ 0x22, 0x11, 0x33 }, encoded);
    try std.testing.expectEqualDeep(value, try SquareSsz.decode(encoded));
}

test "SSZ ProgressiveContainer delegates variable fields to Container encoding" {
    const Message = struct {
        id: u8,
        data: []const u8,
    };
    const overrides = .{ .data = ssz.ByteList(4) };
    const MessageSsz = ssz.ProgressiveContainer(
        Message,
        [_]bool{ false, true, true },
        overrides,
    );
    const RegularSsz = ssz.Container(Message, overrides);
    const value = Message{ .id = 7, .data = "ab" };
    var progressive_storage: [7]u8 = undefined;
    var regular_storage: [7]u8 = undefined;

    const encoded = try MessageSsz.encode(&progressive_storage, value);
    const regular = try RegularSsz.encode(&regular_storage, value);
    try std.testing.expectEqualSlices(u8, regular, encoded);
    try std.testing.expectEqualSlices(u8, &.{ 7, 5, 0, 0, 0, 'a', 'b' }, encoded);

    var decoded = try MessageSsz.decodeAlloc(std.testing.allocator, encoded);
    defer MessageSsz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(value.id, decoded.id);
    try std.testing.expectEqualStrings(value.data, decoded.data);
}
