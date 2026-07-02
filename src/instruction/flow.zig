const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

const CallFrame = Interpreter.CallFrame;

pub fn pc(frame: *CallFrame) !void {
    const current_offset = @as(u256, frame.pc - 1);
    try frame.stack.push(current_offset);
}

pub fn jump(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    frame.pc = std.math.cast(usize, offset) orelse {
        frame.failWithStatus(.invalid);
        return;
    };
    try afterJump(frame);
}

pub fn jumpi(frame: *CallFrame) !void {
    const offset, const condition = try frame.stack.popN(2);
    if (condition != 0) {
        frame.pc = std.math.cast(usize, offset) orelse {
            frame.failWithStatus(.invalid);
            return;
        };
        try afterJump(frame);
    }
}

pub fn afterJump(frame: *CallFrame) !void {
    if (!try frame.isValidJumpDest(frame.pc)) {
        frame.failWithStatus(.invalid);
    }
}

test "jump destinations reject bounds and PUSH data" {
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x00, .JUMP }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x02, .JUMP, .JUMPDEST }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x04, .JUMP, .STOP, .JUMPDEST }, .success);
}
