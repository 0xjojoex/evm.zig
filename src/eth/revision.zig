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

    pub fn order(self: Self, other: Self) std.math.Order {
        return std.math.order(@intFromEnum(self), @intFromEnum(other));
    }

    pub fn isImpl(self: Self, revision: Self) bool {
        return self.order(revision) != .lt;
    }
};

/// Build revision queries from the ordering primitive owned by `R`.
///
/// Zig cannot add methods to a caller-owned enum, so family authoring code uses
/// the returned namespace for derived queries such as `isImpl`. The enum may
/// alias `Model(@This()).isImpl` to retain method syntax. Optional `revisions`,
/// `latest`, and `stable` declarations on `R` become part of the model.
pub fn Model(comptime R: type) type {
    switch (@typeInfo(R)) {
        .@"enum" => {},
        else => @compileError("eth.revision.Model expects an enum type"),
    }
    if (!@hasDecl(R, "order")) {
        @compileError("eth.revision.Model requires R.order(R, R) std.math.Order");
    }
    const order_fn: *const fn (R, R) std.math.Order = R.order;
    const revisions: ?[]const R = if (@hasDecl(R, "revisions")) R.revisions else null;
    const latest: ?R = if (@hasDecl(R, "latest")) R.latest else null;
    const stable: ?R = if (@hasDecl(R, "stable")) R.stable else null;
    return support.ModelWithConfig(R, .{
        .revisions = revisions,
        .latest = latest,
        .stable = stable,
        .order = order_fn,
    });
}

pub const model = Model(Revision);
pub const Availability = model.Availability;
pub const Support = model.Support;
pub const resolveAvailability = model.resolveAvailability;

test "linear fork checks" {
    try std.testing.expectEqual(Revision.amsterdam, Revision.latest);
    try std.testing.expectEqual(Revision.osaka, Revision.stable);
    try std.testing.expectEqual(std.math.Order.lt, Revision.cancun.order(.prague));
    try std.testing.expect(Revision.amsterdam.isImpl(.osaka));
    try std.testing.expect(Revision.osaka.isImpl(.prague));
    try std.testing.expect(Revision.prague.isImpl(.cancun));
    try std.testing.expect(!Revision.prague.isImpl(.osaka));
}

test "caller revision order derives isImpl" {
    const FamilyRevision = enum(u8) {
        first = 10,
        second = 5,

        const Self = @This();

        pub const latest = Self.second;
        pub const stable = Self.first;

        pub fn order(self: Self, other: Self) std.math.Order {
            const self_index: u8 = switch (self) {
                .first => 0,
                .second => 1,
            };
            const other_index: u8 = switch (other) {
                .first => 0,
                .second => 1,
            };
            return std.math.order(self_index, other_index);
        }

        pub const isImpl = Model(Self).isImpl;
    };
    const FamilyRevisions = Model(FamilyRevision);

    try std.testing.expectEqual(FamilyRevision, FamilyRevisions.Revision);
    try std.testing.expectEqual(FamilyRevision.second, FamilyRevisions.latest);
    try std.testing.expectEqual(FamilyRevision.first, FamilyRevisions.stable);
    try std.testing.expect(FamilyRevisions.isImpl(.second, .first));
    try std.testing.expect(!FamilyRevisions.isImpl(.first, .second));
    try std.testing.expect(FamilyRevision.second.isImpl(.first));
}
