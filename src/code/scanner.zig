const std = @import("std");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const BitSet = std.DynamicBitSetUnmanaged;

/// Marks jump destinations and reports whether any instruction boundary is an
/// action opcode, from the same pass.
pub fn markJumpDestsAndClassifyActions(map: *BitSet, bytes: []const u8) bool {
    std.debug.assert(map.bit_length >= bytes.len);
    const word_bits = @bitSizeOf(usize);
    const mask_count = (map.bit_length + word_bits - 1) / word_bits;
    return markJumpDests(map.masks[0..mask_count], bytes);
}

/// The same scan over raw bitset words, so comptime preparation shares it.
/// `masks` must already be zeroed and cover every bit of `bytes`.
pub fn markJumpDests(masks: []usize, bytes: []const u8) bool {
    var needs_action_loop = false;
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode_byte = bytes[pc];
        if (opcode_byte == Opcode.JUMPDEST.toByte()) {
            const shift: std.math.Log2Int(usize) = @truncate(pc);
            masks[pc / @bitSizeOf(usize)] |= @as(usize, 1) << shift;
        }
        if (!needs_action_loop and isActionBoundaryOpcode(opcode_byte)) {
            needs_action_loop = true;
        }

        const push_offset = opcode_byte -% Opcode.PUSH1.toByte();
        pc += if (push_offset < 32) @as(usize, push_offset) + 2 else 1;
    }
    return needs_action_loop;
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

fn referenceAnalyze(map: *BitSet, bytes: []const u8) bool {
    var needs_action_loop = false;
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        if (opcode == .JUMPDEST) map.set(pc);
        needs_action_loop = needs_action_loop or switch (opcode) {
            .CREATE, .CALL, .CALLCODE, .DELEGATECALL, .CREATE2, .STATICCALL => true,
            else => false,
        };

        var next = pc + 1;
        if (opcode.isPushN()) next += opcode.toByte() - Opcode.PUSH0.toByte();
        pc = @min(bytes.len, next);
    }
    return needs_action_loop;
}

test "action classification matches instruction oracle" {
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
            try std.testing.expectEqual(
                referenceAnalyze(&expected, bytecode[0..short_len]),
                markJumpDestsAndClassifyActions(&map, bytecode[0..short_len]),
            );
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
        try std.testing.expectEqual(
            referenceAnalyze(&expected, bytecode[0..len]),
            markJumpDestsAndClassifyActions(&map, bytecode[0..len]),
        );
        try std.testing.expect(map.eql(expected));
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

test "scanner skips a complete PUSH payload" {
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
