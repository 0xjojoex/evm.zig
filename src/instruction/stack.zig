const Interpreter = @import("../Interpreter.zig");
const utils = @import("../utils.zig");

pub inline fn push0(ip: *Interpreter) !void {
    try ip.stack.push(0);
}

pub inline fn pushN(ip: *Interpreter, comptime n: u8) !void {
    if (n < 1 or n > 32) {
        @compileError("pushN: n must e in the range 1..32");
    }
    const value = ip.bytes[ip.pc .. ip.pc + n];

    try ip.stack.push(utils.bytesToU256(value));
    ip.pc += n;
}

pub inline fn pop(ip: *Interpreter) !void {
    _ = try ip.stack.pop();
}

pub inline fn dup(ip: *Interpreter, comptime n: u8) !void {
    if (n < 1 or n > 32) {
        @compileError("dup: n must be in the range 1..16");
    }
    try ip.stack.dup(n);
}

pub inline fn swap(ip: *Interpreter, comptime n: u8) !void {
    if (n < 1 or n > 16) {
        @compileError("swap: n must be in the range 1..16");
    }
    try ip.stack.swap(n);
}
