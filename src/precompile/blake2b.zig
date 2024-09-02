const std = @import("std");
const mem = std.mem;
const math = std.math;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

/// exactly 213 bytes
const input_size = 213;

/// https://eips.ethereum.org/EIPS/eip-152
///
/// rounds - the number of rounds - 32-bit unsigned big-endian word
/// h - the state vector - 8 unsigned 64-bit little-endian words
/// m - the message block vector - 16 unsigned 64-bit little-endian words
/// t_0, t_1 - offset counters - 2 unsigned 64-bit little-endian words
/// f - the final block indicator flag - 8-bit word
pub fn executeF(input: []u8) !void {
    if (input.len != input_size) {
        return error.InvalidInputSize;
    }

    const f = input[212];

    if (f != 0 and f != 1) {
        return error.InvalidFinalBlockFlag;
    }

    const rounds = @byteSwap(@as(u32, @bitCast(input[0..4])));
    var h: [8]u64 = @bitCast(input[4..68]);
    const m: [16]u64 = @bitCast(input[68..196]);
    const t_0: u64 = @bitCast(input[196..204]);
    const t_1: u64 = @bitCast(input[204..212]);

    compress(rounds, &h, m, t_0, t_1, f != 0);
}

pub fn compress(rounds: u32, h: *[8]u64, m: [16]u64, t_0: u64, t_1: u64, f: bool) [64]u8 {
    _ = rounds;
    _ = h;
    _ = m;
    _ = t_0;
    _ = t_1;
    _ = f;

    // var d = Blake2b512.init(.{});
}

const RoundParam = struct {
    a: usize,
    b: usize,
    c: usize,
    d: usize,
    x: usize,
    y: usize,
};

fn roundParam(a: usize, b: usize, c: usize, d: usize, x: usize, y: usize) RoundParam {
    return RoundParam{
        .a = a,
        .b = b,
        .c = c,
        .d = d,
        .x = x,
        .y = y,
    };
}

const iv = [8]u64{
    0x6a09e667f3bcc908,
    0xbb67ae8584caa73b,
    0x3c6ef372fe94f82b,
    0xa54ff53a5f1d36f1,
    0x510e527fade682d1,
    0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b,
    0x5be0cd19137e2179,
};

const sigma = [12][16]u8{
    [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    [_]u8{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    [_]u8{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    [_]u8{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    [_]u8{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    [_]u8{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    [_]u8{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    [_]u8{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    [_]u8{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    [_]u8{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
    [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    [_]u8{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
};

fn customRound(round: u8, h: *[8]u8, m: [16]u8, t_0: u8, t_1: u8, last: bool) void {
    var m: [16]u64 = undefined;
    var v: [16]u64 = undefined;

    for (&m, 0..) |*r, i| {
        r.* = mem.readInt(u64, b[8 * i ..][0..8], .little);
    }

    var k: usize = 0;
    while (k < 8) : (k += 1) {
        v[k] = d.h[k];
        v[k + 8] = iv[k];
    }

    v[12] ^= @as(u64, @truncate(d.t));
    v[13] ^= @as(u64, @intCast(d.t >> 64));
    if (last) v[14] = ~v[14];

    const rounds = comptime [_]RoundParam{
        roundParam(0, 4, 8, 12, 0, 1),
        roundParam(1, 5, 9, 13, 2, 3),
        roundParam(2, 6, 10, 14, 4, 5),
        roundParam(3, 7, 11, 15, 6, 7),
        roundParam(0, 5, 10, 15, 8, 9),
        roundParam(1, 6, 11, 12, 10, 11),
        roundParam(2, 7, 8, 13, 12, 13),
        roundParam(3, 4, 9, 14, 14, 15),
    };

    comptime var j: usize = 0;
    inline while (j < round) : (j += 1) {
        inline for (rounds) |r| {
            v[r.a] = v[r.a] +% v[r.b] +% m[sigma[j][r.x]];
            v[r.d] = math.rotr(u64, v[r.d] ^ v[r.a], @as(usize, 32));
            v[r.c] = v[r.c] +% v[r.d];
            v[r.b] = math.rotr(u64, v[r.b] ^ v[r.c], @as(usize, 24));
            v[r.a] = v[r.a] +% v[r.b] +% m[sigma[j][r.y]];
            v[r.d] = math.rotr(u64, v[r.d] ^ v[r.a], @as(usize, 16));
            v[r.c] = v[r.c] +% v[r.d];
            v[r.b] = math.rotr(u64, v[r.b] ^ v[r.c], @as(usize, 63));
        }
    }

    for (&d.h, 0..) |*r, i| {
        r.* ^= v[i] ^ v[i + 8];
    }
}
