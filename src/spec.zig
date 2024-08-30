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
    gray_glaicer,
    merge,
    shanghai,
    cancun,
    prague,
    prague_eof,

    pub const latest = Self.cancun;

    const Self = @This();

    pub fn isImpl(self: Self, spec: Self) bool {
        return @intFromEnum(self) >= @intFromEnum(spec);
    }
};
