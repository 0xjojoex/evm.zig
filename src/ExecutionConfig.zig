//! Per-execution jumpdest preprocessing strategy, passed into a `Vm` at init.

const ExecutionConfig = @This();

pub const JumpDestStrategy = enum {
    legacy,
    scalar_bitmask,
    simd_bitmask,
};

jumpdest_strategy: JumpDestStrategy = .scalar_bitmask,

pub const base = ExecutionConfig{};

const testing = @import("std").testing;

test "base config uses scalar jumpdest preprocessing" {
    try testing.expectEqual(JumpDestStrategy.scalar_bitmask, ExecutionConfig.base.jumpdest_strategy);
}

test "config can explicitly opt into SIMD jumpdest preprocessing" {
    const config = ExecutionConfig{ .jumpdest_strategy = .simd_bitmask };

    try testing.expectEqual(JumpDestStrategy.simd_bitmask, config.jumpdest_strategy);
}
