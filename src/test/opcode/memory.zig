const evmz = @import("../../evm.zig");

test "MSTORE overwrites already expanded memory" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{
        .PUSH1,  0xaa,
        .PUSH1,  0x00,
        .MSTORE, .PUSH1,
        0xbb,    .PUSH1,
        0x00,    .MSTORE,
        .PUSH1,  0x00,
        .MLOAD,
    }, 0xbb);
}

test "MCOPY is only enabled from Cancun" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH0, .PUSH0, .PUSH0, .MCOPY }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH0, .PUSH0, .PUSH0, .MCOPY }, .cancun, .success);
}

test "MCOPY zero length ignores out of bounds offsets" {
    try evmz.t.expectLatestForkBytecodeStatus(
        .{
            .PUSH0, .PUSH0, .PUSH32,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   .MCOPY,
        },
        .success,
    );
}
