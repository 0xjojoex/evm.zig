const std = @import("std");
const evmz = @import("evmz");
const zbench = @import("zbench");

const uint256 = evmz.uint256;

const ops_per_run = 256;
const bench_config = zbench.Config{
    .max_iterations = 4096,
    .time_budget_ns = 50 * std.time.ns_per_ms,
};

test "micro/arithmetic/sdiv" {
    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("sdiv/small-mixed", benchSdivSmallMixed, .{});
    try bench.add("sdiv/wide-mixed", benchSdivWideMixed, .{});
    try bench.add("sdiv/min-overflow", benchSdivMinOverflow, .{});

    try bench.run(std.testing.io, .stdout());
}

test "micro/arithmetic/smod" {
    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("smod/small-mixed", benchSmodSmallMixed, .{});
    try bench.add("smod/wide-mixed", benchSmodWideMixed, .{});

    try bench.run(std.testing.io, .stdout());
}

test "micro/arithmetic/mulmod" {
    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("mulmod/small", benchMulmodSmall, .{});
    try bench.add("mulmod/wide", benchMulmodWide, .{});
    try bench.add("mulmod/large-modulus", benchMulmodLargeModulus, .{});
    try bench.add("mulmod/large-u512-oracle", benchMulmodLargeU512Oracle, .{});
    try bench.add("mulmod/max-modulus", benchMulmodMaxModulus, .{});

    try bench.run(std.testing.io, .stdout());
}

test "micro/arithmetic/addmod" {
    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("addmod/small", benchAddmodSmall, .{});
    try bench.add("addmod/wide", benchAddmodWide, .{});

    try bench.run(std.testing.io, .stdout());
}

fn benchSdivSmallMixed(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const negative_base: u256 = @bitCast(@as(i256, -987_654_321));
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.sdiv(negative_base -% lane, 3 + lane);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSdivWideMixed(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const high_negative: u256 = @bitCast(@as(i256, std.math.minInt(i256) + 0x1234));
    const divisor: u256 = @bitCast(@as(i256, -0x1_0000_0000));
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.sdiv(high_negative +% lane, divisor -% lane);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSdivMinOverflow(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const min_word: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    const neg_one: u256 = @bitCast(@as(i256, -1));
    for (0..ops_per_run) |i| {
        std.mem.doNotOptimizeAway(i);
        acc +%= uint256.sdiv(min_word, neg_one);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSmodSmallMixed(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const negative_base: u256 = @bitCast(@as(i256, -123_456_789));
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.smod(negative_base -% lane, 97 + lane);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSmodWideMixed(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const high_negative: u256 = @bitCast(@as(i256, std.math.minInt(i256) + 0x4567));
    const divisor: u256 = @bitCast(@as(i256, -0x1_0000_0000_0000));
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.smod(high_negative +% lane, divisor -% lane);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchMulmodSmall(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.mulMod(3 + lane, 5 + lane, 97);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchMulmodWide(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const max = std.math.maxInt(u256);
    const modulus = max - 58;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.mulMod(max -% lane, 0x1_0000_0000_0000 + lane, modulus);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchMulmodLargeModulus(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const lhs = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef;
    const rhs = 0x123456789abcdef0fedcba9876543210123456789abcdef0fedcba9876543210;
    const modulus = 0x8123456789abcdef00112233445566778899aabbccddeeff1020304050607080;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.mulMod(lhs -% lane, rhs +% lane, modulus);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchMulmodLargeU512Oracle(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const lhs = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef;
    const rhs = 0x123456789abcdef0fedcba9876543210123456789abcdef0fedcba9876543210;
    const modulus = 0x8123456789abcdef00112233445566778899aabbccddeeff1020304050607080;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= @intCast((@as(u512, lhs -% lane) * (rhs +% lane)) % modulus);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchMulmodMaxModulus(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const max = std.math.maxInt(u256);
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.mulMod(max -% lane, lane | 1, max);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchAddmodSmall(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.addMod(3 + lane, 5 + lane, 97);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchAddmodWide(_: std.mem.Allocator) void {
    var acc: u256 = 0;
    const max = std.math.maxInt(u256);
    const modulus = max - 58;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        std.mem.doNotOptimizeAway(lane);
        acc +%= uint256.addMod(max -% lane, 0x1_0000_0000_0000 + lane, modulus);
    }
    std.mem.doNotOptimizeAway(acc);
}
