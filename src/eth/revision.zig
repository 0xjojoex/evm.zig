const std = @import("std");
const support = @import("../protocol/support.zig");

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

    pub fn isImpl(self: Self, revision: Self) bool {
        return @intFromEnum(self) >= @intFromEnum(revision);
    }
};

pub const model = support.Model(Revision);
pub const Availability = model.Availability;
pub const Support = model.Support;
pub const resolveAvailability = model.resolveAvailability;

test "linear fork checks" {
    try std.testing.expectEqual(Revision.amsterdam, Revision.latest);
    try std.testing.expectEqual(Revision.osaka, Revision.stable);
    try std.testing.expect(Revision.amsterdam.isImpl(.osaka));
    try std.testing.expect(Revision.osaka.isImpl(.prague));
    try std.testing.expect(Revision.prague.isImpl(.cancun));
    try std.testing.expect(!Revision.prague.isImpl(.osaka));
}
