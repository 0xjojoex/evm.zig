const std = @import("std");
const evmz = @import("evmz");
const zbench = @import("zbench");

test {
    _ = @import("micro_state.zig");
}

const uint256 = evmz.uint256;
const scanner = evmz.code.scanner;

const ops_per_run = 256;
const raw_mask_ops_per_run = 256;
const raw_mask_sample_len = 4096;
const jumpdest_map_ops_per_run = 64;
const jumpdest_small_len = 64;
const jumpdest_large_len = 4096;
const bench_config = zbench.Config{
    .max_iterations = 4096,
    .time_budget_ns = 50 * std.time.ns_per_ms,
};

var raw_mask_bytes: [raw_mask_sample_len]u8 = undefined;
var jumpdest_small_bytes: [jumpdest_small_len]u8 = undefined;
var jumpdest_large_bytes: [jumpdest_large_len]u8 = undefined;

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

test "micro/code/raw-masks" {
    initRawMaskInput();

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("raw-masks/simd-16", benchRawSimdMasks16, .{});
    try bench.add("raw-masks/scalar-16", benchRawScalarMasks16, .{});
    try bench.add("raw-masks/scalar-15", benchRawScalarMasks15, .{});

    try bench.run(std.testing.io, .stdout());
}

test "micro/code/jumpdest-map" {
    initJumpDestInput(&jumpdest_small_bytes);
    initJumpDestInput(&jumpdest_large_bytes);

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("jumpdest-map/scalar-64b", benchJumpDestMapScalarSmall, .{});
    try bench.add("jumpdest-map/simd-64b", benchJumpDestMapSimdSmall, .{});
    try bench.add("jumpdest-map/scalar-4096b", benchJumpDestMapScalarLarge, .{});
    try bench.add("jumpdest-map/simd-4096b", benchJumpDestMapSimdLarge, .{});

    try bench.run(std.testing.io, .stdout());
}

fn benchSdivSmallMixed(_: std.mem.Allocator) void {
    var negative_base: u256 = @bitCast(@as(i256, -987_654_321));
    var divisor: u256 = 3;
    std.mem.doNotOptimizeAway(&negative_base);
    std.mem.doNotOptimizeAway(&divisor);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.sdiv(negative_base -% lane, divisor + lane);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchSdivWideMixed(_: std.mem.Allocator) void {
    var high_negative: u256 = @bitCast(@as(i256, std.math.minInt(i256) + 0x1234));
    var divisor: u256 = @bitCast(@as(i256, -0x1_0000_0000));
    std.mem.doNotOptimizeAway(&high_negative);
    std.mem.doNotOptimizeAway(&divisor);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.sdiv(high_negative +% lane, divisor -% lane);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchSdivMinOverflow(_: std.mem.Allocator) void {
    var min_word: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    var neg_one: u256 = @bitCast(@as(i256, -1));
    std.mem.doNotOptimizeAway(&min_word);
    std.mem.doNotOptimizeAway(&neg_one);

    var acc: u256 = 0;
    for (0..ops_per_run) |_| {
        acc +%= uint256.sdiv(min_word, neg_one);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchSmodSmallMixed(_: std.mem.Allocator) void {
    var negative_base: u256 = @bitCast(@as(i256, -123_456_789));
    var divisor: u256 = 97;
    std.mem.doNotOptimizeAway(&negative_base);
    std.mem.doNotOptimizeAway(&divisor);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.smod(negative_base -% lane, divisor + lane);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchSmodWideMixed(_: std.mem.Allocator) void {
    var high_negative: u256 = @bitCast(@as(i256, std.math.minInt(i256) + 0x4567));
    var divisor: u256 = @bitCast(@as(i256, -0x1_0000_0000_0000));
    std.mem.doNotOptimizeAway(&high_negative);
    std.mem.doNotOptimizeAway(&divisor);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.smod(high_negative +% lane, divisor -% lane);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchMulmodSmall(_: std.mem.Allocator) void {
    var lhs: u256 = 3;
    var rhs: u256 = 5;
    var modulus: u256 = 97;
    std.mem.doNotOptimizeAway(&lhs);
    std.mem.doNotOptimizeAway(&rhs);
    std.mem.doNotOptimizeAway(&modulus);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.mulMod(lhs + lane, rhs + lane, modulus);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchMulmodWide(_: std.mem.Allocator) void {
    var max: u256 = std.math.maxInt(u256);
    var rhs: u256 = 0x1_0000_0000_0000;
    var modulus: u256 = max - 58;
    std.mem.doNotOptimizeAway(&max);
    std.mem.doNotOptimizeAway(&rhs);
    std.mem.doNotOptimizeAway(&modulus);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.mulMod(max -% lane, rhs + lane, modulus);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchMulmodLargeModulus(_: std.mem.Allocator) void {
    var lhs: u256 = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef;
    var rhs: u256 = 0x123456789abcdef0fedcba9876543210123456789abcdef0fedcba9876543210;
    var modulus: u256 = 0x8123456789abcdef00112233445566778899aabbccddeeff1020304050607080;
    std.mem.doNotOptimizeAway(&lhs);
    std.mem.doNotOptimizeAway(&rhs);
    std.mem.doNotOptimizeAway(&modulus);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.mulMod(lhs -% lane, rhs +% lane, modulus);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchMulmodLargeU512Oracle(_: std.mem.Allocator) void {
    var lhs: u256 = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef;
    var rhs: u256 = 0x123456789abcdef0fedcba9876543210123456789abcdef0fedcba9876543210;
    var modulus: u256 = 0x8123456789abcdef00112233445566778899aabbccddeeff1020304050607080;
    std.mem.doNotOptimizeAway(&lhs);
    std.mem.doNotOptimizeAway(&rhs);
    std.mem.doNotOptimizeAway(&modulus);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= @intCast((@as(u512, lhs -% lane) * (rhs +% lane)) % modulus);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchMulmodMaxModulus(_: std.mem.Allocator) void {
    var max: u256 = std.math.maxInt(u256);
    var odd_mask: u256 = 1;
    std.mem.doNotOptimizeAway(&max);
    std.mem.doNotOptimizeAway(&odd_mask);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.mulMod(max -% lane, lane | odd_mask, max);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchAddmodSmall(_: std.mem.Allocator) void {
    var lhs: u256 = 3;
    var rhs: u256 = 5;
    var modulus: u256 = 97;
    std.mem.doNotOptimizeAway(&lhs);
    std.mem.doNotOptimizeAway(&rhs);
    std.mem.doNotOptimizeAway(&modulus);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.addMod(lhs + lane, rhs + lane, modulus);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn benchAddmodWide(_: std.mem.Allocator) void {
    var max: u256 = std.math.maxInt(u256);
    var rhs: u256 = 0x1_0000_0000_0000;
    var modulus: u256 = max - 58;
    std.mem.doNotOptimizeAway(&max);
    std.mem.doNotOptimizeAway(&rhs);
    std.mem.doNotOptimizeAway(&modulus);

    var acc: u256 = 0;
    for (0..ops_per_run) |i| {
        const lane: u256 = @intCast(i + 1);
        acc +%= uint256.addMod(max -% lane, rhs + lane, modulus);
    }
    std.mem.doNotOptimizeAway(&acc);
}

fn initRawMaskInput() void {
    var seed: u64 = 0x9e37_79b9_7f4a_7c15;
    for (&raw_mask_bytes, 0..) |*byte, index| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(seed >> 24);
        if (index % 53 == 0) byte.* = @intFromEnum(evmz.Opcode.JUMPDEST);
        if (index % 47 == 0) byte.* = @intFromEnum(evmz.Opcode.PUSH1) + @as(u8, @truncate(index % 32));
    }
    std.mem.doNotOptimizeAway(raw_mask_bytes[0]);
}

fn initJumpDestInput(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @intFromEnum(evmz.Opcode.ADD);
        if (index % 16 == 0) byte.* = @intFromEnum(evmz.Opcode.PUSH1);
        if (index % 16 == 1) byte.* = @intFromEnum(evmz.Opcode.JUMPDEST);
        if (index % 11 == 0) byte.* = @intFromEnum(evmz.Opcode.JUMPDEST);
    }
    bytes[bytes.len - 1] = @intFromEnum(evmz.Opcode.JUMPDEST);
    std.mem.doNotOptimizeAway(bytes[0]);
}

fn benchRawSimdMasks16(_: std.mem.Allocator) void {
    var acc: u64 = 0;
    for (0..raw_mask_ops_per_run) |i| {
        const index = (i * scanner.lanes) & (raw_mask_sample_len - scanner.lanes);
        std.mem.doNotOptimizeAway(index);
        const masks = scanner.rawSimdMasks(raw_mask_bytes[index..][0..scanner.lanes]);
        acc +%= masks.push ^ (masks.jumpdest << 1);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchJumpDestMapScalarSmall(allocator: std.mem.Allocator) void {
    benchJumpDestMap(allocator, &jumpdest_small_bytes, .scalar_bitmask);
}

fn benchJumpDestMapSimdSmall(allocator: std.mem.Allocator) void {
    benchJumpDestMap(allocator, &jumpdest_small_bytes, .simd_bitmask);
}

fn benchJumpDestMapScalarLarge(allocator: std.mem.Allocator) void {
    benchJumpDestMap(allocator, &jumpdest_large_bytes, .scalar_bitmask);
}

fn benchJumpDestMapSimdLarge(allocator: std.mem.Allocator) void {
    benchJumpDestMap(allocator, &jumpdest_large_bytes, .simd_bitmask);
}

fn benchJumpDestMap(allocator: std.mem.Allocator, bytes: []const u8, strategy: evmz.ExecutionConfig.JumpDestStrategy) void {
    var accepted: usize = 0;
    for (0..jumpdest_map_ops_per_run) |_| {
        var map = evmz.code.JumpDestMap.initWithStrategy(strategy);
        map.analyze(allocator, bytes) catch unreachable;
        accepted +%= @intFromBool(map.isValid(allocator, bytes, bytes.len - 1) catch unreachable);
        map.deinit(allocator);
    }
    std.mem.doNotOptimizeAway(accepted);
}

fn benchRawScalarMasks16(_: std.mem.Allocator) void {
    var acc: u64 = 0;
    for (0..raw_mask_ops_per_run) |i| {
        const index = (i * scanner.lanes) & (raw_mask_sample_len - scanner.lanes);
        std.mem.doNotOptimizeAway(index);
        const masks = scanner.rawScalarMasks(raw_mask_bytes[index..][0..scanner.lanes]);
        acc +%= masks.push ^ (masks.jumpdest << 1);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchRawScalarMasks15(_: std.mem.Allocator) void {
    var acc: u64 = 0;
    for (0..raw_mask_ops_per_run) |i| {
        const index = (i * scanner.lanes) & (raw_mask_sample_len - scanner.lanes);
        std.mem.doNotOptimizeAway(index);
        const masks = scanner.rawScalarMasks(raw_mask_bytes[index..][0 .. scanner.lanes - 1]);
        acc +%= masks.push ^ (masks.jumpdest << 1);
    }
    std.mem.doNotOptimizeAway(acc);
}
