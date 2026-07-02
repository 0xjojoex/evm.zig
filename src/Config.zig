const Config = @This();

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

pub const base = Config{ .preprocessing = .jumpdest };
pub const advanced = Config{ .preprocessing = .full };

pub fn jumpDestStrategy(self: Config) JumpDestStrategy {
    return switch (self.preprocessing) {
        .none => .legacy,
        .jumpdest, .full => .simd_bitmask,
    };
}

pub fn buildsFullAnalysis(self: Config) bool {
    return self.preprocessing == .full;
}

const testing = @import("std").testing;

test "base config uses SIMD jumpdest without full analysis" {
    try testing.expectEqual(JumpDestStrategy.simd_bitmask, Config.base.jumpDestStrategy());
    try testing.expect(!Config.base.buildsFullAnalysis());
}

test "advanced config keeps full analysis slot and SIMD jumpdest seed" {
    try testing.expectEqual(JumpDestStrategy.simd_bitmask, Config.advanced.jumpDestStrategy());
    try testing.expect(Config.advanced.buildsFullAnalysis());
}
