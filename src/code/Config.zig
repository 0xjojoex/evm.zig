//! Per-execution jumpdest preprocessing strategy, passed into a `Vm` at init.

const ExecutionConfig = @This();

pub const JumpDestStrategy = enum {
    legacy,
    scalar_bitmask,
    simd_bitmask,
};

jumpdest_strategy: JumpDestStrategy = .scalar_bitmask,

pub const base = ExecutionConfig{};
