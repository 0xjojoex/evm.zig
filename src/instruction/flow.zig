const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

const CallFrame = Interpreter.CallFrame;

pub fn pc(frame: *CallFrame) !void {
    const current_offset = @as(u256, frame.pc - 1);
    _ = frame.push(current_offset);
}

pub fn jump(frame: *CallFrame) !void {
    const offset = frame.pop() orelse return;
    frame.pc = std.math.cast(usize, offset) orelse {
        frame.halt(.invalid_jump);
        return;
    };
    try afterJump(frame);
}

pub fn jumpi(frame: *CallFrame) !void {
    const offset, const condition = frame.popN(2) orelse return;
    if (condition != 0) {
        frame.pc = std.math.cast(usize, offset) orelse {
            frame.halt(.invalid_jump);
            return;
        };
        try afterJump(frame);
    }
}

pub fn afterJump(frame: *CallFrame) !void {
    if (!try frame.isValidJumpDest(frame.pc)) {
        frame.halt(.invalid_jump);
    }
}

test "jump destinations reject bounds and PUSH data" {
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0xff, .JUMP }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x04, .JUMP, .PUSH1, .JUMPDEST }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x04, .JUMP, .STOP, .JUMPDEST }, .success);
}
