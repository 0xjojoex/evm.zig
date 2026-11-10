const std = @import("std");

/// An Ethereum execution rule set. The state commitment is not part of it and
/// is selected separately: Amsterdam rules over EIP-8297's binary tree (the
/// `BinaryTree` fixture network) are still `.amsterdam`, so a commitment
/// change never adds a value here. Gas repricing that came with a commitment
/// would, as an ordinary new rule set.
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
    /// Hegotá's execution layer, in development: not `latest` until its
    /// headliner (EIP-8141 frame transactions) is complete.
    bogota,

    /// The latest supported revision.
    pub const latest = Self.amsterdam;

    /// The latest stable revision.
    pub const stable = Self.osaka;

    const Self = @This();

    pub fn order(self: Self, other: Self) std.math.Order {
        return std.math.order(@backingInt(self), @backingInt(other));
    }

    pub fn isImpl(self: Self, revision: Self) bool {
        return self.order(revision) != .lt;
    }
};

test "linear fork checks" {
    try std.testing.expectEqual(Revision.amsterdam, Revision.latest);
    try std.testing.expectEqual(Revision.osaka, Revision.stable);
    try std.testing.expectEqual(std.math.Order.lt, Revision.cancun.order(.prague));
    try std.testing.expect(Revision.bogota.isImpl(.amsterdam));
    try std.testing.expect(Revision.amsterdam.isImpl(.osaka));
    try std.testing.expect(Revision.osaka.isImpl(.prague));
    try std.testing.expect(Revision.prague.isImpl(.cancun));
    try std.testing.expect(!Revision.prague.isImpl(.osaka));
}
