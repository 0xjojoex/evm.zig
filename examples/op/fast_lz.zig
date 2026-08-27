//! FastLZ compressed-length estimator used by the OP Fjord L1 cost function.
//!
//! Faithful port of op-revm `fast_lz.rs` / op-geth `rollup_cost.go`
//! `FlzCompressLen`, themselves ports of solady's `LibZip` estimator. The
//! u32 index arithmetic is part of the consensus definition — keep it.

const std = @import("std");

/// Length of `input` after FastLZ level-1 compression.
pub fn compressedLen(input: []const u8) u32 {
    var idx: u32 = 2;
    const idx_limit: u32 = if (input.len < 13) 0 else @intCast(input.len - 13);
    var anchor: u32 = 0;
    var size: u32 = 0;
    var htab = [_]u32{0} ** 8192;

    while (idx < idx_limit) {
        var r: u32 = 0;
        while (true) {
            const seq = u24At(input, idx);
            const slot = hash(seq);
            r = htab[slot];
            htab[slot] = idx;
            const distance = idx - r;
            if (idx >= idx_limit) break;
            idx += 1;
            if (distance < 8192 and seq == u24At(input, r)) break;
        }
        if (idx >= idx_limit) break;
        idx -= 1;
        if (idx > anchor) size = literals(idx - anchor, size);
        const len = cmp(input, r + 3, idx + 3, idx_limit + 9);
        size = match(len, size);
        idx = setNextHash(&htab, input, idx + len);
        idx = setNextHash(&htab, input, idx);
        anchor = idx;
    }
    return literals(@as(u32, @intCast(input.len)) - anchor, size);
}

fn literals(run: u32, size: u32) u32 {
    const grown = size + 0x21 * (run / 0x20);
    const rest = run % 0x20;
    return if (rest != 0) grown + rest + 1 else grown;
}

fn cmp(input: []const u8, p: u32, q: u32, r_bound: u32) u32 {
    var l: u32 = 0;
    var r = r_bound - q;
    // The mismatch branch zeroes the bound after the increment; the reference
    // implementations return `l` one past the mismatch on purpose.
    while (l < r) : (l += 1) {
        if (input[p + l] != input[q + l]) r = 0;
    }
    return l;
}

fn match(len: u32, size: u32) u32 {
    const l = len - 1;
    const grown = size + 3 * (l / 262);
    return if (l % 262 >= 6) grown + 3 else grown + 2;
}

fn setNextHash(htab: *[8192]u32, input: []const u8, idx: u32) u32 {
    htab[hash(u24At(input, idx))] = idx;
    return idx + 1;
}

fn hash(v: u32) u16 {
    return @as(u16, @truncate((@as(u64, v) * 2654435769) >> 19)) & 0x1fff;
}

fn u24At(input: []const u8, idx: u32) u32 {
    return @as(u32, input[idx]) +
        (@as(u32, input[idx + 1]) << 8) +
        (@as(u32, input[idx + 2]) << 16);
}

test "compressedLen matches the op-revm reference vectors" {
    try std.testing.expectEqual(@as(u32, 0), compressedLen(&.{}));
    try std.testing.expectEqual(@as(u32, 21), compressedLen(&[_]u8{0} ** 1000));
    try std.testing.expectEqual(@as(u32, 21), compressedLen(&[_]u8{42} ** 1000));
    try std.testing.expectEqual(@as(u32, 4), compressedLen(&.{ 0xfa, 0xca, 0xde }));

    // Sample contract call from the op-revm test suite.
    const sample_hex =
        "02f901550a758302df1483be21b88304743f94f80e51afb613d764fa61751affd3313c190a86bb870151bd62fd12adb8e41ef24f3f000000000000000000000000000000000000000000000000000000000000006e000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831000000000000000000000000000000000000000000000000000000000003c1e5" ++
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000148c89ed219d02f1a5be012c689b4f5b731827bebe000000000000000000000000c001a033fd89cb37c31b2cba46b6466e040c61" ++
        "fc9b2a3675a7f5f493ebd5ad77c497f8a07cdf65680e238392693019b4092f610222e71b7cec06449cb922b93b6a12744e";
    var sample: [sample_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sample, sample_hex);
    try std.testing.expectEqual(@as(u32, 202), compressedLen(&sample));
}

test "compressedLen grows monotonically on incompressible input" {
    var input: [256]u8 = undefined;
    var len: u32 = 0;
    for (0..256) |i| {
        input[i] = @intCast(i);
        const previous = len;
        len = compressedLen(input[0 .. i + 1]);
        try std.testing.expect(len > previous);
    }
}
