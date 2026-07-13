const std = @import("std");
const ssz = @import("../lib.zig");
const compatibility = @import("../compatibility.zig");
const fixed = @import("fixed.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;

/// Represent a Zig integer enum as its SSZ unsigned-integer tag type.
pub fn IntEnum(comptime E: type) type {
    const enum_info = switch (@typeInfo(E)) {
        .@"enum" => |info| info,
        else => @compileError("SSZ IntEnum requires a Zig enum"),
    };
    const Tag = enum_info.tag_type;
    const TagCodec = fixed.Fixed(Tag);

    return struct {
        pub const Value = E;
        pub const kind: codec.Kind = .basic;
        pub const schema_type = Tag;
        pub const is_variable_size = false;
        pub const fixed_size = TagCodec.fixed_size;
        pub const requires_allocator = false;

        pub fn encodedLen(_: Value) Error!usize {
            return fixed_size.?;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            return TagCodec.encode(out, @as(Tag, @intFromEnum(value)));
        }

        pub fn decode(bytes: []const u8) Error!Value {
            const tag = try TagCodec.decode(bytes);
            inline for (enum_info.fields) |field| {
                if (tag == field.value) return @enumFromInt(tag);
            }
            return error.InvalidEnumValue;
        }

        pub fn validate(bytes: []const u8) Error!void {
            _ = try decode(bytes);
        }
    };
}

test "SSZ IntEnum uses the enum tag's integer schema" {
    const Mode = enum(u16) {
        inactive = 0,
        active = 7,
    };
    const ModeSsz = ssz.IntEnum(Mode);
    var encoded: [2]u8 = undefined;

    try std.testing.expect(compatibility.compatible(ModeSsz, ssz.Fixed(u16)));
    try std.testing.expectEqualSlices(u8, &.{ 7, 0 }, try ModeSsz.encode(&encoded, .active));
    try std.testing.expectEqual(Mode.active, try ModeSsz.decode(&encoded));
    try std.testing.expectError(error.InvalidEnumValue, ModeSsz.decode(&.{ 1, 0 }));
}
