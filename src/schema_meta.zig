const std = @import("std");
const fixed = @import("basic/fixed.zig");

pub fn vectorElementCodec(comptime Codec: type) type {
    if (@hasDecl(Codec, "element_codec")) return Codec.element_codec;
    const array = switch (@typeInfo(Codec.Value)) {
        .array => |value| value,
        else => @compileError("SSZ vector codec does not expose its element codec"),
    };
    return fixed.Fixed(array.child);
}

pub fn vectorLength(comptime Codec: type) usize {
    if (@hasDecl(Codec, "length")) return Codec.length;
    return switch (@typeInfo(Codec.Value)) {
        .array => |value| value.len,
        else => @compileError("SSZ vector codec does not expose its length"),
    };
}

pub fn containerFieldCodec(
    comptime ContainerCodec: type,
    comptime name: []const u8,
    comptime T: type,
) type {
    if (std.meta.hasFn(ContainerCodec, "FieldCodec")) return ContainerCodec.FieldCodec(name, T);
    if (@hasDecl(ContainerCodec, "field_overrides")) {
        const overrides = ContainerCodec.field_overrides;
        if (@hasField(@TypeOf(overrides), name)) return @field(overrides, name);
    }
    return fixed.Fixed(T);
}
