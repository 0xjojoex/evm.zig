const evmz = @import("../../evm.zig");

test "BYTE with large offset pushes zero" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH1, 0x01, .PUSH1, 0xff, .BYTE }, 0);
}

test "CLZ is only enabled from Osaka" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x01, .CLZ }, .prague, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x01, .CLZ }, .osaka, .success);
}

test "CLZ treats zero as a value and counts leading zero bits in an EVM word" {
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH0, .CLZ }, .osaka, 256);
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH1, 0x01, .CLZ }, .osaka, 255);
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH1, 0x80, .CLZ }, .osaka, 248);
}
