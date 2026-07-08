//! Per-execution tuning: bytecode preprocessing strategy and jumpdest-analysis
//! backend, passed into a `Vm` at init.

const ExecutionConfig = @This();

pub const Preprocessing = enum {
    none,
    jumpdest,
    full,
};

pub const JumpDestStrategy = enum {
    legacy,
    scalar_bitmask,
    simd_bitmask,
};

preprocessing: Preprocessing = .jumpdest,
jumpdest_strategy: JumpDestStrategy = .scalar_bitmask,

pub const base = ExecutionConfig{ .preprocessing = .jumpdest };
pub const advanced = ExecutionConfig{ .preprocessing = .full };

pub fn jumpDestStrategy(self: ExecutionConfig) JumpDestStrategy {
    return switch (self.preprocessing) {
        .none => .legacy,
        .jumpdest, .full => self.jumpdest_strategy,
    };
}

pub fn buildsFullAnalysis(self: ExecutionConfig) bool {
    return self.preprocessing == .full;
}

pub fn buildsJumpDestMap(self: ExecutionConfig) bool {
    return self.preprocessing != .none;
}

const testing = @import("std").testing;

test "base config uses scalar jumpdest without full analysis" {
    try testing.expectEqual(JumpDestStrategy.scalar_bitmask, ExecutionConfig.base.jumpDestStrategy());
    try testing.expect(!ExecutionConfig.base.buildsFullAnalysis());
    try testing.expect(ExecutionConfig.base.buildsJumpDestMap());
}

test "advanced config keeps full analysis slot and scalar jumpdest seed" {
    try testing.expectEqual(JumpDestStrategy.scalar_bitmask, ExecutionConfig.advanced.jumpDestStrategy());
    try testing.expect(ExecutionConfig.advanced.buildsFullAnalysis());
    try testing.expect(ExecutionConfig.advanced.buildsJumpDestMap());
}

test "config can explicitly opt into SIMD jumpdest preprocessing" {
    const config = ExecutionConfig{ .jumpdest_strategy = .simd_bitmask };

    try testing.expectEqual(JumpDestStrategy.simd_bitmask, config.jumpDestStrategy());
}

test "no preprocessing leaves jumpdest map unbuilt" {
    const config = ExecutionConfig{ .preprocessing = .none };

    try testing.expectEqual(JumpDestStrategy.legacy, config.jumpDestStrategy());
    try testing.expect(!config.buildsJumpDestMap());
}
