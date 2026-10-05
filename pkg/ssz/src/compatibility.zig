const std = @import("std");
const ssz = @import("lib.zig");
const compatibility = @import("compatibility.zig");
const codec = @import("codec.zig");
const schema_meta = @import("schema_meta.zig");

/// Return whether two codec schemas have compatible SSZ Merkleization.
pub fn compatible(comptime A: type, comptime B: type) bool {
    codec.assertCodec(A);
    codec.assertCodec(B);
    if (@hasDecl(A, "wire_codec")) return compatible(A.wire_codec, B);
    if (@hasDecl(B, "wire_codec")) return compatible(A, B.wire_codec);
    if (A == B) return true;
    if (A.kind != B.kind) return false;

    return switch (A.kind) {
        .basic => basicSchemaType(A) == basicSchemaType(B),
        .vector => schema_meta.vectorLength(A) == schema_meta.vectorLength(B) and
            compatible(schema_meta.vectorElementCodec(A), schema_meta.vectorElementCodec(B)),
        .list => A.max_length.? == B.max_length.? and
            compatible(A.element_codec, B.element_codec),
        .progressive_list => compatible(A.element_codec, B.element_codec),
        .bitvector => A.length == B.length,
        .bitlist => A.max_length.? == B.max_length.?,
        .progressive_bitlist => true,
        .container => containersCompatible(A, B),
        .progressive_container => progressiveContainersCompatible(A, B),
        .compatible_union => compatibleUnionsCompatible(A, B),
        .union_type => optionalUnionsCompatible(A, B),
    };
}

fn optionalUnionsCompatible(comptime A: type, comptime B: type) bool {
    if (@typeInfo(A.Value) != .optional or @typeInfo(B.Value) != .optional) return false;
    return compatible(A.value_codec, B.value_codec);
}

fn basicSchemaType(comptime Codec: type) type {
    return if (@hasDecl(Codec, "schema_type")) Codec.schema_type else Codec.Value;
}

fn containersCompatible(comptime A: type, comptime B: type) bool {
    const a_info = @typeInfo(A.Value).@"struct";
    const b_info = @typeInfo(B.Value).@"struct";
    if (a_info.field_names.len != b_info.field_names.len) return false;

    inline for (a_info.field_names, a_info.field_types, 0..) |a_field_name, a_field_type, index| {
        const b_field_name = b_info.field_names[index];
        if (!std.mem.eql(u8, a_field_name, b_field_name)) return false;
        if (!compatible(
            schema_meta.containerFieldCodec(A, a_field_name, a_field_type),
            schema_meta.containerFieldCodec(B, b_field_name, b_info.field_types[index]),
        )) return false;
    }
    return true;
}

fn progressiveContainersCompatible(comptime A: type, comptime B: type) bool {
    const a_info = @typeInfo(A.Value).@"struct";
    const b_info = @typeInfo(B.Value).@"struct";

    inline for (a_info.field_names, a_info.field_types, 0..) |a_field_name, a_field_type, a_index| {
        inline for (
            b_info.field_names,
            b_info.field_types,
            0..,
        ) |b_field_name, b_field_type, b_index| {
            const same_name = std.mem.eql(u8, a_field_name, b_field_name);
            const same_position = activePosition(A, a_index) == activePosition(B, b_index);
            if (same_name != same_position) return false;
            if (same_name and !compatible(
                schema_meta.containerFieldCodec(A, a_field_name, a_field_type),
                schema_meta.containerFieldCodec(B, b_field_name, b_field_type),
            )) return false;
        }
    }
    return true;
}

fn activePosition(comptime Codec: type, comptime field_index: usize) usize {
    comptime var seen: usize = 0;
    inline for (Codec.active_fields, 0..) |active, position| {
        if (active) {
            if (seen == field_index) return position;
            seen += 1;
        }
    }
    unreachable;
}

fn compatibleUnionsCompatible(comptime A: type, comptime B: type) bool {
    const a_info = @typeInfo(A.Value).@"union";
    const b_info = @typeInfo(B.Value).@"union";
    inline for (a_info.field_names, a_info.field_types) |a_field_name, a_field_type| {
        inline for (b_info.field_names, b_info.field_types) |b_field_name, b_field_type| {
            if (!compatible(
                A.OptionCodec(a_field_name, a_field_type),
                B.OptionCodec(b_field_name, b_field_type),
            )) return false;
        }
    }
    return true;
}

test "SSZ schema compatibility rejects incompatible Merkle shapes" {
    const First = struct { shared: u16 };
    const Shifted = struct { shared: u16 };
    const FirstSsz = ssz.ProgressiveContainer(First, [_]bool{true}, .{});
    const ShiftedSsz = ssz.ProgressiveContainer(Shifted, [_]bool{ false, true }, .{});

    try std.testing.expect(!compatibility.compatible(FirstSsz, ShiftedSsz));
    try std.testing.expect(!compatibility.compatible(ssz.List(u16, 2), ssz.List(u16, 3)));
    try std.testing.expect(!compatibility.compatible(ssz.Bitvector(4), @import("basic/fixed.zig").Fixed([4]bool)));
}

test "SSZ packed bitfield codecs preserve boolean schema compatibility" {
    try std.testing.expect(compatibility.compatible(
        ssz.Bitvector(10),
        ssz.PackedBitvector(10),
    ));
    try std.testing.expect(compatibility.compatible(
        ssz.Bitlist(16),
        ssz.PackedBitlist(16),
    ));
    try std.testing.expect(compatibility.compatible(
        ssz.ProgressiveBitlist,
        ssz.ProgressivePackedBitlist,
    ));
    try std.testing.expect(!compatibility.compatible(
        ssz.Bitvector(9),
        ssz.PackedBitvector(10),
    ));
    try std.testing.expect(!compatibility.compatible(
        ssz.Bitlist(15),
        ssz.PackedBitlist(16),
    ));
}
