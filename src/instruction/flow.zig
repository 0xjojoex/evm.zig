const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;

const CallFrame = Interpreter.CallFrame;

pub fn pc(frame: *CallFrame) !void {
    const current_offset = @as(u256, frame.pc - 1);
    try frame.stack.push(current_offset);
}

pub fn jump(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    frame.pc = @intCast(offset);
    afterJump(frame);
}

pub fn jumpi(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const condition = try frame.stack.pop();
    if (condition != 0) {
        frame.pc = @intCast(offset);
        afterJump(frame);
    }
}

pub fn afterJump(frame: *CallFrame) void {
    const code: Opcode = @enumFromInt(frame.bytes[frame.pc - 1]);
    if (frame.bytes[frame.pc] != @intFromEnum(Opcode.JUMPDEST) or (code.isPushN())) {
        frame.status = .invalid;
    }
}
