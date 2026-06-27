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

preprocessing: Preprocessing = .none,

pub const base = Config{ .preprocessing = .none };
pub const advanced_jumpdest_only = Config{ .preprocessing = .jumpdest };
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

test "jumpdest preprocessing config uses SIMD jumpdest without full analysis" {
    try @import("std").testing.expectEqual(JumpDestStrategy.simd_bitmask, Config.advanced_jumpdest_only.jumpDestStrategy());
    try @import("std").testing.expect(!Config.advanced_jumpdest_only.buildsFullAnalysis());
}

test "advanced config keeps full analysis slot and SIMD jumpdest seed" {
    try @import("std").testing.expectEqual(JumpDestStrategy.simd_bitmask, Config.advanced.jumpDestStrategy());
    try @import("std").testing.expect(Config.advanced.buildsFullAnalysis());
}
