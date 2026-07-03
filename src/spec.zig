const std = @import("std");

pub const Spec = enum(u8) {
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

    /// The latest supported spec.
    pub const latest = Self.amsterdam;

    /// The latest stable spec.
    pub const stable = Self.osaka;

    const Self = @This();

    pub fn isImpl(self: Self, spec: Self) bool {
        return @intFromEnum(self) >= @intFromEnum(spec);
    }
};

test "linear fork checks" {
    try std.testing.expectEqual(Spec.amsterdam, Spec.latest);
    try std.testing.expectEqual(Spec.osaka, Spec.stable);
    try std.testing.expect(Spec.amsterdam.isImpl(.osaka));
    try std.testing.expect(Spec.osaka.isImpl(.prague));
    try std.testing.expect(Spec.prague.isImpl(.cancun));
    try std.testing.expect(!Spec.prague.isImpl(.osaka));
}
