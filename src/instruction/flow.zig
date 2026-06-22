const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const std = @import("std");

const CallFrame = Interpreter.CallFrame;

pub fn pc(frame: *CallFrame) !void {
    const current_offset = @as(u256, frame.pc - 1);
    try frame.stack.push(current_offset);
}

pub fn jump(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    frame.pc = std.math.cast(usize, offset) orelse {
        frame.status = .invalid;
        return;
    };
    afterJump(frame);
}

pub fn jumpi(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const condition = try frame.stack.pop();
    if (condition != 0) {
        frame.pc = std.math.cast(usize, offset) orelse {
            frame.status = .invalid;
            return;
        };
        afterJump(frame);
    }
}

pub fn afterJump(frame: *CallFrame) void {
    if (!isValidJumpDest(frame.bytes, frame.pc)) {
        frame.status = .invalid;
    }
}

fn isValidJumpDest(bytes: []const u8, target: usize) bool {
    if (target >= bytes.len or bytes[target] != @intFromEnum(Opcode.JUMPDEST)) {
        return false;
    }

    var pc_index: usize = 0;
    while (pc_index < bytes.len) {
        if (pc_index == target) {
            return true;
        }

        const opcode = bytes[pc_index];
        pc_index += 1;
        if (opcode >= @intFromEnum(Opcode.PUSH1) and opcode <= @intFromEnum(Opcode.PUSH32)) {
            pc_index += opcode - @intFromEnum(Opcode.PUSH0);
        }
    }

    return false;
}

test "jump destinations reject bounds and PUSH data" {
    try evmz.t.expectCancunBytecodeStatus(&.{ 0x60, 0x00, 0x56 }, .invalid);
    try evmz.t.expectCancunBytecodeStatus(&.{ 0x60, 0x02, 0x56, 0x5b }, .invalid);
    try evmz.t.expectCancunBytecodeStatus(&.{ 0x60, 0x04, 0x56, 0x00, 0x5b }, .success);
}
