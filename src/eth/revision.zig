const std = @import("std");

pub const Revision = enum(u8) {
    frontier = 0,
    frontier_thawing,
    homestead,
    dao_fork,
    tangerine_whistle,
    spurious_dragon,
    byzantium,
    constantinople,
    petersburg,
    istanbul,
    muir_glacier,
    berlin,
    london,
    arrow_glacier,
    gray_glacier,
    merge,
    shanghai,
    cancun,
    prague,
    osaka,
    amsterdam,

    /// The latest supported revision.
    pub const latest = Self.amsterdam;

    /// The latest stable revision.
    pub const stable = Self.osaka;

    const Self = @This();

    pub fn order(self: Self, other: Self) std.math.Order {
        return std.math.order(@intFromEnum(self), @intFromEnum(other));
    }

    pub fn isImpl(self: Self, revision: Self) bool {
        return self.order(revision) != .lt;
    }
};

test "linear fork checks" {
    try std.testing.expectEqual(Revision.amsterdam, Revision.latest);
    try std.testing.expectEqual(Revision.osaka, Revision.stable);
    try std.testing.expectEqual(std.math.Order.lt, Revision.cancun.order(.prague));
    try std.testing.expect(Revision.amsterdam.isImpl(.osaka));
    try std.testing.expect(Revision.osaka.isImpl(.prague));
    try std.testing.expect(Revision.prague.isImpl(.cancun));
    try std.testing.expect(!Revision.prague.isImpl(.osaka));
}
