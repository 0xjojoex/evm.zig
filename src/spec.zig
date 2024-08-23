const std = @import("std");

const Spec = enum(u8) {
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

    latest = std.math.maxValue(u8),
};
