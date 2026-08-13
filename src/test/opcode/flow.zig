const evmz = @import("../../evm.zig");

test "jump destinations reject bounds and PUSH data" {
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0xff, .JUMP }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x04, .JUMP, .PUSH1, .JUMPDEST }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x04, .JUMP, .STOP, .JUMPDEST }, .success);
}
