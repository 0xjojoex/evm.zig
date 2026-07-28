const std = @import("std");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const BitSet = std.DynamicBitSetUnmanaged;

pub const lanes = 16;

const RawMasks = struct {
    push: u64,
    jumpdest: u64,
};

const ClassifiedRawMasks = struct {
    raw: RawMasks,
    action: u64,
};

const BoundaryMasks = struct {
    boundary: u64,
    jumpdest: u64,
};

/// Marks jump destinations and reports whether any instruction boundary is an
/// action opcode, from the same pass.
pub fn markJumpDestsAndClassifyActions(map: *BitSet, bytes: []const u8) bool {
    return markScan(map, bytes, true);
}

fn markScan(map: *BitSet, bytes: []const u8, comptime classify_actions: bool) bool {
    var index: usize = 0;
    var carry_payload: usize = 0;
    var needs_action_loop = false;

    while (index < bytes.len) : (index += lanes) {
        const chunk = bytes[index..@min(index + lanes, bytes.len)];
        const masks = rawMasksClassified(chunk, classify_actions);
        const boundaries = resolveBoundaryMasks(chunk, masks.raw.push, masks.raw.jumpdest, &carry_payload);
        orMask(map, index, boundaries.jumpdest);
        if (classify_actions) {
            needs_action_loop = needs_action_loop or masks.action & boundaries.boundary != 0;
        }
    }

    return needs_action_loop;
}

fn orMask(bitset: *BitSet, base: usize, mask: u64) void {
    if (mask == 0) return;

    const MaskInt = BitSet.MaskInt;
    const word_bits = @bitSizeOf(MaskInt);
    const first_word = base / word_bits;
    // @truncate is base % word_bits, since word_bits is a power of two.
    const offset: BitSet.ShiftInt = @truncate(base);

    // A 16-lane chunk can straddle two bitset words, so shift the mask into
    // place and spill whatever hangs off the top into the next word:
    //
    //   base = 60, mask = 0b1011_0001   (lanes 60, 64, 65, 67)
    //     word[0] |= mask << 60         -> lane 60; bits past 63 shift out
    //     word[1] |= mask >> 4          -> 0b1011, lanes 64, 65, 67
    bitset.masks[first_word] |= @as(MaskInt, @intCast(mask)) << offset;
    if (offset != 0 and first_word + 1 < numMasks(bitset.bit_length)) {
        const right_shift: BitSet.ShiftInt = @intCast(word_bits - @as(usize, offset));
        bitset.masks[first_word + 1] |= @as(MaskInt, @intCast(mask >> right_shift));
    }
}

fn numMasks(bit_length: usize) usize {
    const MaskInt = BitSet.MaskInt;
    return (bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
}

const swar_ones: u64 = 0x0101010101010101;
const swar_highs: u64 = 0x8080808080808080;
const swar_lows: u64 = ~swar_highs;

/// High bit of each zero byte in `word` becomes set; other high bits clear.
///
/// The `(word -% ones) & ~word` form is one op cheaper but borrows across lanes,
/// so a zero byte makes a neighbouring `0x01` byte read as zero too. Adding
/// `0x7f` to the low 7 bits keeps every carry inside its own lane instead.
inline fn swarZeroBytes(word: u64) u64 {
    // Per lane: (b & 0x7f) + 0x7f sets bit 7 iff b's low 7 bits are non-zero.
    // OR-ing b back in covers bit 7 itself, so the OR is 0xff unless b == 0.
    //
    //   b       (b & 0x7f) + 0x7f    | b | 0x7f    ~
    //   0x00    0x00 + 0x7f = 0x7f   0x7f          0x80   <- zero byte
    //   0x5b    0x5b + 0x7f = 0xda   0xff          0x00
    //   0x80    0x00 + 0x7f = 0x7f   0xff          0x00
    //
    // 0x7f + 0x7f = 0xfe never carries out of the byte, so lanes stay isolated.
    // The borrowing form would read `5b 5a` (JUMPDEST GAS) as two zero lanes.
    return ~(((word & swar_lows) +% swar_lows) | word | swar_lows);
}

/// Compress per-byte high bits (0x80 lanes) into one bit per byte, byte 0 -> bit 0.
inline fn swarMoveMask(high_bits: u64) u64 {
    // Byte k's high bit sits at 7+8k. The constant is 2^0+2^7+...+2^49 — eight
    // terms spaced 7 apart — so multiplying shifts a copy by each term, and the
    // term 7*(7-k) lands byte k's bit on exactly 56+k:
    //
    //   0x80 in byte 0 -> bit  7 + 49 -> bit 56 -> >>56 -> bit 0
    //   0x80 in byte 1 -> bit 15 + 42 -> bit 57 -> >>56 -> bit 1
    //   0x80 in byte 7 -> bit 63 +  0 -> bit 63 -> >>56 -> bit 7
    //
    // Every other copy lands below bit 56 or overflows past 63. No two copies
    // share a bit position, so the multiply never carries and the sum is exact.
    return (high_bits *% 0x0002040810204081) >> 56;
}

const SwarWordMasks = struct {
    push: u64,
    jumpdest: u64,
    high_f0: u64,
};

inline fn swarWordMasks(word: u64) SwarWordMasks {
    // There is no per-byte `==` in a scalar register, so each test XORs the
    // wanted value in: a matching lane becomes 0x00, and swarZeroBytes turns
    // exactly those lanes into 0x80. `swar_ones * v` broadcasts v at comptime.
    //
    // Running example, bytes low -> high (PUSH1, data, JUMPDEST, CALL, STOP..):
    //
    //   lane:       0     1     2     3     4..7
    //   byte:      0x60  0x01  0x5b  0xf1  0x00
    //
    // PUSH1..PUSH32 is 0x60..0x7f, i.e. "top 3 bits are 011":
    //
    //   & 0xe0:    0x60  0x00  0x40  0xe0  0x00
    //   ^ 0x60:    0x00  0x60  0x20  0x80  0x60   -> lane 0 -> push bit 0
    const push_zero = (word & (swar_ones * 0xe0)) ^ (swar_ones * 0x60);

    // JUMPDEST is one exact value, so a bare XOR is the whole test:
    //
    //   ^ 0x5b:    0x3b  0x5a  0x00  0xaa  0x5b   -> lane 2 -> jumpdest bit 2
    const jumpdest_zero = word ^ (swar_ones * @as(u64, Opcode.JUMPDEST.toByte()));

    // 0xf0..0xff is the only row action opcodes live in, i.e. "top nibble f":
    //
    //   & 0xf0:    0x60  0x00  0x50  0xf0  0x00
    //   ^ 0xf0:    0x90  0xf0  0xa0  0x00  0xf0   -> lane 3 -> candidate
    const high_zero = (word & (swar_ones * 0xf0)) ^ (swar_ones * 0xf0);

    return .{
        .push = swarMoveMask(swarZeroBytes(push_zero)),
        .jumpdest = swarMoveMask(swarZeroBytes(jumpdest_zero)),
        // Left as 0x80 lanes: the caller usually only needs "is it zero?" and
        // skips the move-mask entirely.
        .high_f0 = swarZeroBytes(high_zero),
    };
}

fn rawMasksClassified(bytes: []const u8, comptime classify_actions: bool) ClassifiedRawMasks {
    var chunk: [lanes]u8 = @splat(0);
    @memcpy(chunk[0..bytes.len], bytes);
    var push: u64 = 0;
    var jumpdest: u64 = 0;
    var action: u64 = 0;
    // Two u64 words cover the 16-lane chunk. Little-endian keeps byte order and
    // bit order aligned: chunk[i] is word bit 8i, so word 1's 8-bit mask just
    // shifts up to lanes 8..15.
    inline for (0..lanes / 8) |word_index| {
        const word = std.mem.readInt(u64, chunk[word_index * 8 ..][0..8], .little);
        const masks = swarWordMasks(word);
        push |= masks.push << (word_index * 8);
        jumpdest |= masks.jumpdest << (word_index * 8);
        // Action opcodes all live in the rare 0xF0-0xFF row; resolve those
        // bytes individually only when the word contains that row at all.
        if (classify_actions and masks.high_f0 != 0) {
            var candidates = swarMoveMask(masks.high_f0);
            while (candidates != 0) {
                // Walk only the set bits: @ctz finds the lowest, then
                // `x &= x - 1` clears it (borrowing flips the trailing zeros).
                //
                //   0b0010_1000 - 1 = 0b0010_0111
                //   0b0010_1000 &     0b0010_0111 = 0b0010_0000   bit 3 gone
                const lane: u6 = @intCast(@ctz(candidates));
                candidates &= candidates - 1;
                const byte = chunk[word_index * 8 + lane];
                const bit = @as(u64, @intFromBool(isActionBoundaryOpcode(byte)));
                action |= bit << (@as(u6, word_index * 8) + lane);
            }
        }
    }
    return .{
        .raw = .{ .push = push, .jumpdest = jumpdest },
        .action = action,
    };
}

pub inline fn isActionBoundaryOpcode(opcode_byte: u8) bool {
    // Wrapping subtraction folds "is it in 0xf0..0xf5" into one unsigned
    // compare: anything below 0xf0 wraps up past the bound instead of going
    // negative, so no second `>= 0xf0` test is needed.
    //
    //   0xf0 CREATE     -> 0x00 <= 0x05   yes
    //   0xf1 CALL       -> 0x01 <= 0x05   yes
    //   0xf3 RETURN     -> 0x03 <= 0x05   in range, excluded by name below
    //   0xfa STATICCALL -> 0x0a >  0x05   caught by the second test
    //   0x5b JUMPDEST   -> 0x6b >  0x05   no (wrapped far above the bound)
    const system_offset = opcode_byte -% Opcode.CREATE.toByte();
    return (system_offset <= Opcode.CREATE2.toByte() - Opcode.CREATE.toByte() and
        opcode_byte != Opcode.RETURN.toByte()) or
        opcode_byte == Opcode.STATICCALL.toByte();
}

/// Turn the raw per-byte masks into "which lanes are real instruction
/// boundaries", by covering every PUSH immediate.
///
/// A PUSH's payload can hide bytes that look like opcodes, and can run off the
/// end of the chunk, so `carry_payload` carries the overhang to the next call.
//
//   chunk:      5b   61   5b   5b   00      (JUMPDEST PUSH2 <data> <data> STOP)
//   lane:        0    1    2    3    4
//
//   raw push     0b0000_0010                PUSH2 at lane 1
//   payload     |0b0000_1100                covers lanes 2..3
//   boundary     0b1111_0011 & valid_lanes  -> lanes 0, 1, 4
//   raw jumpdest 0b0000_1101
//   & boundary   0b0000_0001                only lane 0 survives
fn resolveBoundaryMasks(bytes: []const u8, raw_push_mask: u64, raw_jumpdest_mask: u64, carry_payload: *usize) BoundaryMasks {
    const len = bytes.len;
    // Short tail chunks are zero-padded up to `lanes`; ignore the padding.
    const valid_lanes = lowMask(len);

    if (carry_payload.* >= len) {
        carry_payload.* -= len;
        return .{ .boundary = 0, .jumpdest = 0 };
    }

    var payload_mask = lowMask(carry_payload.*);
    carry_payload.* = 0;

    var push_mask = raw_push_mask & valid_lanes;
    while (push_mask != 0) {
        const bit: usize = @intCast(@ctz(push_mask));
        push_mask &= push_mask - 1;

        // A PUSH-looking byte already covered by an earlier PUSH's payload is
        // data, not an instruction, so it opens no payload of its own.
        const bit_mask = @as(u64, 1) << @intCast(bit);
        if ((payload_mask & bit_mask) != 0) continue;

        const opcode: Opcode = @enumFromInt(bytes[bit]);
        const push_len: usize = opcode.toByte() - Opcode.PUSH0.toByte();
        const payload_start = bit + 1;
        const payload_end = payload_start + push_len;
        if (payload_start < len) {
            payload_mask |= rangeMask(payload_start, @min(push_len, len - payload_start));
        }
        if (payload_end > len) {
            carry_payload.* = payload_end - len;
        }
    }

    const boundary = ~payload_mask & valid_lanes;
    return .{
        .boundary = boundary,
        .jumpdest = raw_jumpdest_mask & boundary,
    };
}

/// The low `count` bits set.
//   count = 3 -> (1 << 3) - 1 = 0b0000_0111
fn lowMask(count: usize) u64 {
    if (count == 0) return 0;
    if (count >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(count)) - 1;
}

/// `count` bits set starting at bit `start`.
//   start = 2, count = 3 -> 0b0000_0111 << 2 = 0b0001_1100
fn rangeMask(start: usize, count: usize) u64 {
    if (count == 0) return 0;
    return lowMask(count) << @intCast(start);
}

/// Byte-at-a-time definition of the two masks, independent of any SWAR trick.
fn referenceRawMasks(bytes: []const u8) RawMasks {
    var masks = RawMasks{ .push = 0, .jumpdest = 0 };
    for (bytes, 0..) |byte, index| {
        const bit = @as(u64, 1) << @intCast(index);
        if (byte & 0xe0 == 0x60) masks.push |= bit;
        if (byte == Opcode.JUMPDEST.toByte()) masks.jumpdest |= bit;
    }
    return masks;
}

fn referenceNeedsActionLoop(bytes: []const u8) bool {
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        if (switch (opcode) {
            .CREATE, .CALL, .CALLCODE, .DELEGATECALL, .CREATE2, .STATICCALL => true,
            else => false,
        }) return true;

        var next = pc + 1;
        if (opcode.isPushN()) next += opcode.toByte() - Opcode.PUSH0.toByte();
        pc = @min(bytes.len, next);
    }
    return false;
}

test "raw masks place bits at the byte's own lane" {
    inline for (0..lanes) |lane| {
        var bytes = [_]u8{0} ** lanes;
        bytes[lane] = Opcode.PUSH1.toByte();
        try std.testing.expectEqual(@as(u64, 1) << lane, rawMasksClassified(&bytes, false).raw.push);

        bytes = [_]u8{0} ** lanes;
        bytes[lane] = Opcode.JUMPDEST.toByte();
        try std.testing.expectEqual(@as(u64, 1) << lane, rawMasksClassified(&bytes, false).raw.jumpdest);
    }
}

test "raw masks match reference across adjacent-byte combinations" {
    // JUMPDEST (0x5b) next to GAS (0x5a) used to alias: the SWAR zero-byte test
    // borrowed out of the JUMPDEST lane and flagged GAS as a jump destination.
    for (0..lanes - 1) |lane| {
        for (0..256) |first| {
            for (0..256) |second| {
                var bytes = [_]u8{0} ** lanes;
                bytes[lane] = @intCast(first);
                bytes[lane + 1] = @intCast(second);
                const expected = referenceRawMasks(&bytes);
                const actual = rawMasksClassified(&bytes, false).raw;
                try std.testing.expectEqual(expected.push, actual.push);
                try std.testing.expectEqual(expected.jumpdest, actual.jumpdest);
            }
        }
    }
}

test "raw masks match reference on random chunks of every length" {
    var prng = std.Random.DefaultPrng.init(0x7363616e6e6572);
    const random = prng.random();

    for (0..10_000) |_| {
        var bytes: [lanes]u8 = undefined;
        random.bytes(&bytes);
        const len = random.intRangeAtMost(usize, 1, lanes);
        const chunk = bytes[0..len];
        const expected = referenceRawMasks(chunk);
        const actual = rawMasksClassified(chunk, false).raw;
        try std.testing.expectEqual(expected.push, actual.push);
        try std.testing.expectEqual(expected.jumpdest, actual.jumpdest);
    }
}

test "action classification matches instruction oracle" {
    var bytecode = [_]u8{Opcode.STOP.toByte()} ** 96;
    var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    for (0..lanes) |lane| {
        for (0..256) |byte| {
            @memset(&bytecode, Opcode.STOP.toByte());
            bytecode[lane] = @intCast(byte);
            map.unsetAll();
            try std.testing.expectEqual(
                referenceNeedsActionLoop(bytecode[0..lanes]),
                markJumpDestsAndClassifyActions(&map, bytecode[0..lanes]),
            );
        }
    }

    var prng = std.Random.DefaultPrng.init(0x616374696f6e73);
    const random = prng.random();
    for (0..10_000) |_| {
        random.bytes(&bytecode);
        const len = random.intRangeAtMost(usize, 0, bytecode.len);
        map.unsetAll();
        try std.testing.expectEqual(
            referenceNeedsActionLoop(bytecode[0..len]),
            markJumpDestsAndClassifyActions(&map, bytecode[0..len]),
        );
    }
}

test "scanner marks jumpdests while ignoring PUSH payload noise" {
    const bytecode = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    try std.testing.expect(!markJumpDestsAndClassifyActions(&map, &bytecode));

    try std.testing.expect(!map.isSet(0));
    try std.testing.expect(!map.isSet(1));
    try std.testing.expect(map.isSet(2));
}

test "scanner carries PUSH payload across chunks" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toByte();
    bytecode[1] = Opcode.JUMPDEST.toByte();
    bytecode[31] = Opcode.JUMPDEST.toByte();
    bytecode[33] = Opcode.JUMPDEST.toByte();
    var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    try std.testing.expect(!markJumpDestsAndClassifyActions(&map, &bytecode));

    try std.testing.expect(!map.isSet(1));
    try std.testing.expect(!map.isSet(31));
    try std.testing.expect(map.isSet(33));
}

test "scanner classifies action boundaries while ignoring PUSH payloads" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toByte();
    bytecode[1] = Opcode.CALL.toByte();
    bytecode[33] = Opcode.JUMPDEST.toByte();
    bytecode[34] = Opcode.PUSH1.toByte();
    bytecode[35] = Opcode.STATICCALL.toByte();
    bytecode[36] = Opcode.CREATE2.toByte();

    var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    try std.testing.expect(markJumpDestsAndClassifyActions(&map, &bytecode));
    try std.testing.expect(map.isSet(33));

    bytecode[36] = Opcode.STOP.toByte();
    map.unsetAll();
    try std.testing.expect(!markJumpDestsAndClassifyActions(&map, &bytecode));
}
