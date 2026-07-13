const std = @import("std");
const ssz = @import("../lib.zig");
const compatibility = @import("../compatibility.zig");
const fixed = @import("../basic/fixed.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;

/// Represent an SSZ List[FixedT, 1] as Zig ?FixedT.
pub fn OptionalList(comptime T: type) type {
    const ElementCodec = fixed.Fixed(T);
    const element_size = ElementCodec.fixed_size.?;

    return struct {
        pub const Value = ?T;
        pub const kind: codec.Kind = .list;
        pub const element_codec = ElementCodec;
        pub const max_length: ?comptime_int = 1;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = false;

        pub fn encodedLen(value: Value) Error!usize {
            return if (value == null) 0 else element_size;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            const item = value orelse return out[0..0];
            if (out.len < element_size) return error.BufferTooSmall;
            return ElementCodec.encode(out[0..element_size], item);
        }

        pub fn decode(bytes: []const u8) Error!Value {
            if (bytes.len == 0) return null;
            if (bytes.len != element_size) return error.InvalidByteLength;
            return try ElementCodec.decode(bytes);
        }

        pub fn validate(bytes: []const u8) Error!void {
            _ = try decode(bytes);
        }
    };
}

test "SSZ OptionalList represents List[FixedT, 1] as an optional" {
    const Optional = ssz.OptionalList(u64);
    const Canonical = ssz.List(u64, 1);
    const one = [_]u64{42};
    var optional_storage: [8]u8 = undefined;
    var canonical_storage: [8]u8 = undefined;

    try std.testing.expect(!Optional.requires_allocator);
    try std.testing.expect(compatibility.compatible(Optional, Canonical));
    try std.testing.expectEqualSlices(
        u8,
        try Canonical.encode(&canonical_storage, &one),
        try Optional.encode(&optional_storage, 42),
    );
    try std.testing.expectEqual(@as(?u64, 42), try Optional.decode(&optional_storage));
    try std.testing.expectEqual(@as(?u64, null), try Optional.decode(""));
    try std.testing.expectError(error.InvalidByteLength, Optional.decode(&.{0}));
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(Canonical, &one),
        try ssz.hashTreeRoot(Optional, 42),
    );
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(Canonical, &.{}),
        try ssz.hashTreeRoot(Optional, null),
    );
}
