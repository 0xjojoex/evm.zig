const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;

pub fn pc(ip: *Interpreter) !void {
    const current_offset = @as(u256, ip.pc - 1);
    try ip.stack.push(current_offset);
}

pub fn jump(ip: *Interpreter) !void {
    const offset = try ip.stack.pop();
    ip.pc = @intCast(offset);
    afterJump(ip);
}

pub fn jumpi(ip: *Interpreter) !void {
    const offset = try ip.stack.pop();
    const condition = try ip.stack.pop();
    if (condition != 0) {
        ip.pc = @intCast(offset);
        afterJump(ip);
    }
}

pub fn afterJump(ip: *Interpreter) void {
    const code: Opcode = @enumFromInt(ip.bytes[ip.pc - 1]);
    if (ip.bytes[ip.pc] != @intFromEnum(Opcode.JUMPDEST) or (code.isPush())) {
        ip.status = .invalid;
    }
}
