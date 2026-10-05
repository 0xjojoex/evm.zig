const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const BitSet = std.DynamicBitSetUnmanaged;

/// Native targets with a 16-lane byte table lookup run the block scan, which
/// takes the same time on any code. zkVM guests have no branch predictor and
/// would only pay for its extra instructions, so they keep the serial walk.
const block_scan = build_options.profile == .native and
    @bitSizeOf(usize) == 64 and switch (builtin.target.cpu.arch) {
    .aarch64 => builtin.target.cpu.has(.aarch64, .neon),
    .x86_64 => builtin.target.cpu.has(.x86, .ssse3),
    else => false,
};

/// Marks jump destinations. `map` must already be zeroed and cover every
/// bit of `bytes`.
pub fn markJumpDests(map: *BitSet, bytes: []const u8) void {
    std.debug.assert(map.bit_length >= bytes.len);
    const word_bits = @bitSizeOf(usize);
    const mask_count = (map.bit_length + word_bits - 1) / word_bits;
    if (comptime block_scan)
        markJumpDestBlocks(map.masks[0..mask_count], bytes)
    else
        markJumpDestWords(map.masks[0..mask_count], bytes);
}

const Lanes = @Vector(16, u8);

/// One mask word per 64-byte block, without a branch that depends on the code
/// (after ethrex#7311). A per-opcode scan mispredicts on most bytes of random
/// JUMPDEST/PUSH1 code (execution-specs#3631). `masks` must already be zeroed
/// and cover every bit of `bytes`.
fn markJumpDestBlocks(masks: []usize, bytes: []const u8) void {
    comptime std.debug.assert(block_scan);
    var walks: Walks = undefined;
    // Immediate bytes of a PUSH that spills out of the previous block; at most 32.
    var carry: usize = 0;
    const full = bytes.len / 64;
    for (masks[0..full], 0..) |*mask, index| mask.* = markBlock(bytes[index * 64 ..][0..64], &carry, &walks);
    if (bytes.len % 64 != 0) {
        // Zero padding decodes as STOP, so the short tail marks nothing extra.
        var tail: [64]u8 = @splat(0);
        @memcpy(tail[0 .. bytes.len % 64], bytes[full * 64 ..]);
        masks[full] = markBlock(&tail, &carry, &walks);
    }
}

/// For each byte of a block, the walk that starts if that byte is an opcode,
/// up to where it leaves its 16-byte group: the block-relative position it
/// leaves to, and the group bytes it lands on (`low` bytes 0-7, `high` 8-15).
const Walks = struct {
    exits: [64]u8,
    low: [64]u8,
    high: [64]u8,
};

inline fn markBlock(chunk: *const [64]u8, carry: *usize, walks: *Walks) u64 {
    const Block = @Vector(64, u8);
    const block: Block = chunk.*;
    const jumpdests: u64 = @bitCast(block == @as(Block, @splat(Opcode.JUMPDEST.toByte())));
    inline for (0..4) |group| {
        const start = group * 16;
        const walk = groupWalks(chunk[start..][0..16].*);
        walks.exits[start..][0..16].* = walk.exits +% @as(Lanes, @splat(start));
        walks.low[start..][0..16].* = walk.low;
        walks.high[start..][0..16].* = walk.high;
    }
    // Where a walk leaves a group is where it enters the next, so four dependent
    // loads follow the real walk; once past the block it stays put.
    var at = carry.*;
    var opcodes: u64 = 0;
    inline for (0..4) |_| {
        const inside = at < 64;
        const i = at % 64;
        const stops = @as(u64, walks.low[i]) | @as(u64, walks.high[i]) << 8;
        opcodes |= (if (inside) stops else 0) << @intCast(i & 48);
        at = if (inside) walks.exits[i] else at;
    }
    carry.* = at - 64;
    return jumpdests & opcodes;
}

/// All 16 walks of a group advance together by pointer doubling: each round, a
/// walk still inside continues with the walk of the byte it reached. A step
/// moves at least one byte, so four rounds take every walk out of the group.
inline fn groupWalks(bytes: Lanes) struct { exits: Lanes, low: Lanes, high: Lanes } {
    // PUSH1..PUSH32 are exactly 0b011x_xxxx.
    const is_push = bytes & @as(Lanes, @splat(0xe0)) == @as(Lanes, @splat(Opcode.PUSH1.toByte()));
    const immediates = @select(u8, is_push, bytes -% @as(Lanes, @splat(Opcode.PUSH1.toByte() - 1)), @as(Lanes, @splat(0)));
    var exits = @as(Lanes, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }) +% immediates;
    var low: Lanes = .{ 1, 2, 4, 8, 16, 32, 64, 128, 0, 0, 0, 0, 0, 0, 0, 0 };
    var high: Lanes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 4, 8, 16, 32, 64, 128 };
    // A lookup past the group reads zero, so a walk that left keeps its stops
    // and `@max` keeps its exit. Low stops come within a walk's first eight
    // steps, so the last round skips them.
    inline for (0..4) |round| {
        if (round < 3) low |= lookup(low, exits);
        high |= lookup(high, exits);
        exits = @max(exits, lookup(exits, exits));
    }
    return .{ .exits = exits, .low = low, .high = high };
}

/// Lane `i` of `table` for each index below 16; zero for indices 16 to 143.
/// Zig's `@shuffle` requires comptime indices; these indices are runtime data.
inline fn lookup(table: Lanes, indices: Lanes) Lanes {
    return switch (builtin.target.cpu.arch) {
        .aarch64 => asm ("tbl %[out].16b, { %[table].16b }, %[indices].16b"
            : [out] "=w" (-> Lanes),
            : [table] "w" (table),
              [indices] "w" (indices),
        ),
        // PSHUFB zeroes lanes whose index has its top bit set and otherwise uses
        // the low four bits; +0x70 sets the top bit of 16..143 only.
        .x86_64 => asm ("pshufb %[indices], %[out]"
            : [out] "=x" (-> Lanes),
            : [table] "0" (table),
              [indices] "x" (indices +% @as(Lanes, @splat(0x70))),
        ),
        else => comptime unreachable,
    };
}

/// Serial scan over raw bitset words, shared by comptime preparation and
/// zkVM guests. `masks` must already be zeroed and cover every bit of `bytes`.
pub fn markJumpDestWords(masks: []usize, bytes: []const u8) void {
    const lengths = comptime blk: {
        var result: [256]u8 = @splat(1);
        for (0..32) |i| result[Opcode.PUSH1.toByte() + i] = @intCast(i + 2);
        break :blk result;
    };
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode_byte = bytes[pc];
        if (opcode_byte == Opcode.JUMPDEST.toByte()) {
            const shift: std.math.Log2Int(usize) = @truncate(pc);
            masks[pc / @bitSizeOf(usize)] |= @as(usize, 1) << shift;
        }

        pc += lengths[opcode_byte];
    }
}

fn referenceMark(map: *BitSet, bytes: []const u8) void {
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        if (opcode == .JUMPDEST) map.set(pc);

        pc = @min(bytes.len, pc + 1 + opcode.pushImmediateLen());
    }
}

test "jumpdest scans match instruction oracle" {
    const word_bits = @bitSizeOf(usize);
    const scans = if (block_scan)
        .{ markJumpDestWords, markJumpDestBlocks }
    else
        .{markJumpDestWords};
    inline for (scans) |mark| {
        var bytecode = [_]u8{Opcode.STOP.toByte()} ** 200;
        var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
        defer map.deinit(std.testing.allocator);
        var expected = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
        defer expected.deinit(std.testing.allocator);

        // Every byte at every lane of two blocks, so each PUSH crosses every
        // group and block boundary. A JUMPDEST filler exposes immediates taken
        // for opcodes; a PUSH1 filler makes each walk depend on every byte before it.
        for ([_]Opcode{ .JUMPDEST, .PUSH1 }) |filler| {
            for (0..130) |lane| {
                for (0..256) |byte| {
                    @memset(&bytecode, filler.toByte());
                    bytecode[lane] = @intCast(byte);
                    map.unsetAll();
                    expected.unsetAll();
                    referenceMark(&expected, bytecode[0..130]);
                    mark(map.masks[0 .. (130 + word_bits - 1) / word_bits], bytecode[0..130]);
                    try std.testing.expect(map.eql(expected));
                }
            }
        }

        var prng = std.Random.DefaultPrng.init(0x616374696f6e73);
        const random = prng.random();
        const mix = [_]Opcode{ .STOP, .JUMPDEST, .PUSH1, .PUSH2, .PUSH16, .PUSH17, .PUSH32 };
        for (0..10_000) |iteration| {
            if (iteration % 2 == 0) {
                random.bytes(&bytecode);
            } else for (&bytecode) |*byte| {
                byte.* = mix[random.uintLessThan(usize, mix.len)].toByte();
            }
            const len = random.intRangeAtMost(usize, 0, bytecode.len);
            map.unsetAll();
            expected.unsetAll();
            referenceMark(&expected, bytecode[0..len]);
            mark(map.masks[0 .. (len + word_bits - 1) / word_bits], bytecode[0..len]);
            try std.testing.expect(map.eql(expected));
        }
    }
}

test "scanner marks jumpdests while ignoring PUSH payload noise" {
    const bytecode = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    markJumpDests(&map, &bytecode);

    try std.testing.expect(!map.isSet(0));
    try std.testing.expect(!map.isSet(1));
    try std.testing.expect(map.isSet(2));
}

test "scanner skips a complete PUSH payload" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toByte();
    bytecode[1] = Opcode.JUMPDEST.toByte();
    bytecode[31] = Opcode.JUMPDEST.toByte();
    bytecode[33] = Opcode.JUMPDEST.toByte();
    var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    markJumpDests(&map, &bytecode);

    try std.testing.expect(!map.isSet(1));
    try std.testing.expect(!map.isSet(31));
    try std.testing.expect(map.isSet(33));
}
