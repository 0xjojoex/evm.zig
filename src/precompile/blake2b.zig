const std = @import("std");

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
    var h: [8]u8 = @bitCast(input[4..68]);
    const m: [16]u8 = @bitCast(input[68..196]);
    const t_0: u8 = @bitCast(input[196..204]);
    const t_1: u8 = @bitCast(input[204..212]);

    compress(rounds, &h, m, t_0, t_1, f != 0);
}

pub fn compress(rounds: u32, h: *[8]u8, m: [16]u8, t_0: u8, t_1: u8, f: bool) [64]u8 {
    _ = rounds;
    _ = h;
    _ = m;
    _ = t_0;
    _ = t_1;
    _ = f;
}
