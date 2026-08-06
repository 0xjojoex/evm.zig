const std = @import("std");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const BitSet = std.DynamicBitSetUnmanaged;

/// Marks jump destinations. `map` must already be zeroed and cover every
/// bit of `bytes`.
pub fn markJumpDests(map: *BitSet, bytes: []const u8) void {
    std.debug.assert(map.bit_length >= bytes.len);
    const word_bits = @bitSizeOf(usize);
    const mask_count = (map.bit_length + word_bits - 1) / word_bits;
    markJumpDestWords(map.masks[0..mask_count], bytes);
}

/// The same scan over raw bitset words, so comptime preparation shares it.
/// `masks` must already be zeroed and cover every bit of `bytes`.
pub fn markJumpDestWords(masks: []usize, bytes: []const u8) void {
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode_byte = bytes[pc];
        if (opcode_byte == Opcode.JUMPDEST.toByte()) {
            const shift: std.math.Log2Int(usize) = @truncate(pc);
            masks[pc / @bitSizeOf(usize)] |= @as(usize, 1) << shift;
        }

        const push_offset = opcode_byte -% Opcode.PUSH1.toByte();
        pc += if (push_offset < 32) @as(usize, push_offset) + 2 else 1;
    }
}

fn referenceMark(map: *BitSet, bytes: []const u8) void {
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        if (opcode == .JUMPDEST) map.set(pc);

        var next = pc + 1;
        if (opcode.isPushN()) next += opcode.toByte() - Opcode.PUSH0.toByte();
        pc = @min(bytes.len, next);
    }
}

test "jumpdest scan matches instruction oracle" {
    const short_len = 16;
    var bytecode = [_]u8{Opcode.STOP.toByte()} ** 96;
    var map = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);
    var expected = try BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer expected.deinit(std.testing.allocator);

    for (0..short_len) |lane| {
        for (0..256) |byte| {
            @memset(&bytecode, Opcode.STOP.toByte());
            bytecode[lane] = @intCast(byte);
            map.unsetAll();
            expected.unsetAll();
            referenceMark(&expected, bytecode[0..short_len]);
            markJumpDests(&map, bytecode[0..short_len]);
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
        markJumpDests(&map, bytecode[0..len]);
        try std.testing.expect(map.eql(expected));
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
