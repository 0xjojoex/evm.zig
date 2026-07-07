const ExecutionConfig = @This();

pub const Preprocessing = enum {
    none,
    jumpdest,
    full,
};

pub const JumpDestStrategy = enum {
    legacy,
    simd_bitmask,
};

preprocessing: Preprocessing = .jumpdest,

pub const base = ExecutionConfig{ .preprocessing = .jumpdest };
pub const advanced = ExecutionConfig{ .preprocessing = .full };

pub fn jumpDestStrategy(self: ExecutionConfig) JumpDestStrategy {
    return switch (self.preprocessing) {
        .none => .legacy,
        .jumpdest, .full => .simd_bitmask,
    };
}

pub fn buildsFullAnalysis(self: ExecutionConfig) bool {
    return self.preprocessing == .full;
}

const testing = @import("std").testing;

test "base config uses SIMD jumpdest without full analysis" {
    try testing.expectEqual(JumpDestStrategy.simd_bitmask, ExecutionConfig.base.jumpDestStrategy());
    try testing.expect(!ExecutionConfig.base.buildsFullAnalysis());
}

test "advanced config keeps full analysis slot and SIMD jumpdest seed" {
    try testing.expectEqual(JumpDestStrategy.simd_bitmask, ExecutionConfig.advanced.jumpDestStrategy());
    try testing.expect(ExecutionConfig.advanced.buildsFullAnalysis());
}
