//! Packed `{offset, len}` handles into a caller-supplied backing array.
//!
//! Arenas that pack variable-length payloads into one flat buffer store these
//! instead of slices: half the width, and stable across buffer growth. The
//! backing array is passed in at read time, so a range carries no lifetime of
//! its own — the owner pairs it with the buffer it was cut from.
//!
//! Instantiations are distinct types, so a handle into the word arena cannot
//! be read against the byte arena by mistake.

const std = @import("std");

/// `Len` narrows the length field where a domain bound allows it, keeping the
/// handle inside one 64-bit word.
pub fn Range(comptime T: type, comptime Len: type) type {
    return struct {
        offset: u32 = 0,
        len: Len = 0,

        const Self = @This();

        /// The caller owns any domain bound on `len`; this checks only what
        /// the representation can hold.
        pub fn init(offset: usize, len: usize) Self {
            std.debug.assert(offset <= std.math.maxInt(u32));
            std.debug.assert(len <= std.math.maxInt(Len));
            std.debug.assert(offset + len <= std.math.maxInt(u32));
            return .{ .offset = @intCast(offset), .len = @intCast(len) };
        }

        pub fn slice(self: Self, items: []const T) []const T {
            const offset: usize = self.offset;
            const len: usize = self.len;
            std.debug.assert(offset + len <= items.len);
            return items[offset..][0..len];
        }
    };
}

pub const Bytes = Range(u8, u32);

comptime {
    std.debug.assert(@sizeOf(Bytes) == 8);
}

test "range slices its backing array and stays byte-identical across widths" {
    const Words = Range(u256, u32);
    const Narrow = Range(u256, u8);

    const bytes = [_]u8{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqualSlices(u8, bytes[1..4], Bytes.init(1, 3).slice(&bytes));

    const words = [_]u256{ 7, 8, 9 };
    try std.testing.expectEqualSlices(u256, words[2..3], Narrow.init(2, 1).slice(&words));
    try std.testing.expectEqualSlices(u256, words[0..0], (Words{}).slice(&words));

    try std.testing.expectEqual(8, @sizeOf(Bytes));
    try std.testing.expectEqual(8, @sizeOf(Words));
    try std.testing.expectEqual(8, @sizeOf(Narrow));
}
