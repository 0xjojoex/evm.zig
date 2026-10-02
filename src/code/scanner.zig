const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const BitSet = std.DynamicBitSetUnmanaged;

/// zkVM guests pay for every scalarized vector lane, so they keep the serial
/// walk; native CPUs resolve a 64-byte block per wide compare.
/// Vector mask casts map lane 0 to bit 0 only on little-endian targets.
const block_scan = build_options.profile == .native and
    @bitSizeOf(usize) == 64 and builtin.target.cpu.arch.endian() == .little;

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

/// One mask word per 64-byte block: vector compares find JUMPDEST and PUSH
/// bytes, then only the PUSH opcodes are walked to clear their immediates.
/// `masks` must already be zeroed and cover every bit of `bytes`.
fn markJumpDestBlocks(masks: []usize, bytes: []const u8) void {
    comptime std.debug.assert(@bitSizeOf(usize) == 64 and builtin.target.cpu.arch.endian() == .little);
    // Immediate bytes of a PUSH that spills out of the previous block; at most 32.
    var carry: u6 = 0;
    const full = bytes.len / 64;
    for (masks[0..full], 0..) |*mask, index| mask.* = markBlock(bytes[index * 64 ..][0..64], &carry);
    if (bytes.len % 64 != 0) {
        // Zero padding decodes as STOP, so the short tail marks nothing extra.
        var tail: [64]u8 = @splat(0);
        @memcpy(tail[0 .. bytes.len % 64], bytes[full * 64 ..]);
        masks[full] = markBlock(&tail, &carry);
    }
}

inline fn markBlock(chunk: *const [64]u8, carry: *u6) u64 {
    const Block = @Vector(64, u8);
    const block: Block = chunk.*;
    const covered = (@as(u64, 1) << carry.*) - 1;
    var jumpdests: u64 = @bitCast(block == @as(Block, @splat(Opcode.JUMPDEST.toByte())));
    var pushes: u64 = @bitCast(block -% @as(Block, @splat(Opcode.PUSH1.toByte())) < @as(Block, @splat(32)));
    jumpdests &= ~covered;
    pushes &= ~covered;
    carry.* = 0;
    while (pushes != 0) {
        const pc: u6 = @intCast(@ctz(pushes));
        const next = @as(usize, pc) + 2 + (chunk[pc] - Opcode.PUSH1.toByte());
        if (next >= 64) {
            // Wraps to all ones at pc == 63.
            jumpdests &= (@as(u64, 2) << pc) -% 1;
            carry.* = @intCast(next - 64);
            break;
        }
        const end = @as(u64, 1) << @intCast(next);
        jumpdests &= ~(end - (@as(u64, 2) << pc));
        pushes &= ~(end - 1);
    }
    return jumpdests;
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

        // Every byte at every lane of a block and its neighbours, including
        // PUSHes whose immediates cross into the next block.
        for (0..130) |lane| {
            for (0..256) |byte| {
                @memset(&bytecode, Opcode.JUMPDEST.toByte());
                bytecode[lane] = @intCast(byte);
                map.unsetAll();
                expected.unsetAll();
                referenceMark(&expected, bytecode[0..130]);
                mark(map.masks[0 .. (130 + word_bits - 1) / word_bits], bytecode[0..130]);
                try std.testing.expect(map.eql(expected));
            }
        }

        var prng = std.Random.DefaultPrng.init(0x616374696f6e73);
        const random = prng.random();
        for (0..10_000) |_| {
            random.bytes(&bytecode);
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
