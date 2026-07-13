const std = @import("std");
const ssz = @import("lib.zig");
const codec = @import("codec.zig");
const bitfield = @import("bitfield.zig");
const schema_meta = @import("schema_meta.zig");
const vector = @import("vector/variable_vector.zig");

/// Adapt a fixed collection codec to allocator-backed slice storage.
pub fn Alloc(comptime Codec: type) type {
    comptime codec.assertCodec(Codec);
    return switch (Codec.kind) {
        .vector => vector.VectorSliceOf(
            schema_meta.vectorElementCodec(Codec),
            schema_meta.vectorLength(Codec),
        ),
        .bitvector => bitfield.BitvectorSlice(Codec.length),
        else => @compileError("ssz.Alloc currently supports vectors and bitvectors"),
    };
}

test "SSZ Alloc gives fixed vectors allocator-backed storage" {
    const Inline = ssz.ByteVector(64);
    const Owned = ssz.Alloc(Inline);
    const bytes = [_]u8{0x5a} ** 64;
    var encoded: [64]u8 = undefined;

    try std.testing.expect(Owned.requires_allocator);
    try std.testing.expectEqual(@as(?usize, 64), Owned.fixed_size);
    try std.testing.expect(Owned.Value == []const u8);
    _ = try Owned.encode(&encoded, &bytes);
    var decoded = try Owned.decodeAlloc(std.testing.allocator, &encoded);
    defer Owned.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualSlices(u8, &bytes, decoded);
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(Inline, bytes),
        try ssz.hashTreeRoot(Owned, decoded),
    );
}
