const evmz = @import("../../evm.zig");

test "PUSH pads missing immediate bytes with zeroes" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH2, 0x01 }, 0x0100);
    try evmz.t.expectLatestForkBytecodeStackTop(.{.PUSH1}, 0);
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH32, 0x01 }, @as(u256, 1) << 248);
}

test "PUSH decodes full immediates" {
    try evmz.t.expectLatestForkBytecodeStackTop(
        .{
            .PUSH32,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
        },
        0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,
    );
}

test "EIP-8024 DUPN duplicates a deep stack item" {
    var code: [20]u8 = undefined;
    code[0] = evmz.Opcode.PUSH1.toByte();
    code[1] = 1;
    @memset(code[2..18], evmz.Opcode.PUSH0.toByte());
    code[18] = evmz.Opcode.DUPN.toByte();
    code[19] = 0x80;

    var expected = [_]u256{0} ** 18;
    expected[0] = 1;
    expected[17] = 1;
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}

test "EIP-8024 SWAPN swaps the top with a deep stack item" {
    var code: [22]u8 = undefined;
    code[0] = evmz.Opcode.PUSH1.toByte();
    code[1] = 1;
    @memset(code[2..18], evmz.Opcode.PUSH0.toByte());
    code[18] = evmz.Opcode.PUSH1.toByte();
    code[19] = 2;
    code[20] = evmz.Opcode.SWAPN.toByte();
    code[21] = 0x80;

    var expected = [_]u256{0} ** 18;
    expected[0] = 2;
    expected[17] = 1;
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}

test "EIP-8024 EXCHANGE swaps two non-top stack items" {
    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH1, 1, .PUSH1, 2, .EXCHANGE, 0x8e });
    const expected = [_]u256{ 1, 0, 2 };
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}

test "EIP-8024 immediates reject jumpdest and push ranges" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .DUPN, 0x5b }, .amsterdam, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .SWAPN, 0x60 }, .amsterdam, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .EXCHANGE, 0x52 }, .amsterdam, .invalid);
}

test "EIP-8024 missing immediate byte is decoded as zero" {
    var code = [_]u8{evmz.Opcode.PUSH0.toByte()} ** 146;
    code[145] = evmz.Opcode.DUPN.toByte();

    const expected = [_]u256{0} ** 146;
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}
